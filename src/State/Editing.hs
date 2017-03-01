{-# LANGUAGE MultiWayIf #-}

module State.Editing where

import           Brick (EventM, Next, suspendAndResume, handleEventLensed)
import           Brick.Widgets.Edit (Editor, handleEditorEvent, getEditContents, editContentsL)
import           Brick.Widgets.Edit (applyEdit)
import qualified Codec.Binary.UTF8.Generic as UTF8
import           Control.Arrow
import           Control.Monad (void)
import           Control.Monad.IO.Class (liftIO)
import qualified Data.ByteString as BS
import qualified Data.HashMap.Strict as HM
import           Data.Monoid ((<>))
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.Zipper as Z
import qualified Data.Text.Zipper.Generic.Words as Z
import           Graphics.Vty (Event(..), Key(..), Modifier(..))
import           Lens.Micro.Platform
import qualified System.Environment as Sys
import qualified System.Exit as Sys
import qualified System.IO as Sys
import qualified System.IO.Temp as Sys
import qualified System.Process as Sys

import           Network.Mattermost
import           Network.Mattermost.Lenses

import           Config
import           Types

import           State.Common

startMultilineEditing :: ChatState -> ChatState
startMultilineEditing = csEditState.cedMultiline .~ True

toggleMultilineEditing :: ChatState -> ChatState
toggleMultilineEditing = csEditState.cedMultiline %~ not

invokeExternalEditor :: ChatState -> EventM Name (Next ChatState)
invokeExternalEditor st = do
    -- If EDITOR is in the environment, write the current message to a
    -- temp file, invoke EDITOR on it, read the result, remove the temp
    -- file, and update the program state.
    --
    -- If EDITOR is not present, fall back to 'vi'.
    mEnv <- liftIO $ Sys.lookupEnv "EDITOR"
    let editorProgram = maybe "vi" id mEnv

    suspendAndResume $
      Sys.withSystemTempFile "matterhorn_editor.tmp" $ \tmpFileName tmpFileHandle -> do
        -- Write the current message to the temp file
        Sys.hPutStr tmpFileHandle $ T.unpack $ T.intercalate "\n" $
            getEditContents $ st^.cmdLine
        Sys.hClose tmpFileHandle

        -- Run the editor
        status <- Sys.system (editorProgram <> " " <> tmpFileName)

        -- On editor exit, if exited with zero status, read temp file.
        -- If non-zero status, skip temp file read.
        case status of
            Sys.ExitSuccess -> do
                tmpBytes <- BS.readFile tmpFileName
                case T.decodeUtf8' tmpBytes of
                    Left _ -> do
                        msg <- newClientMessage Error "Failed to decode file contents as UTF-8"
                        return $ addClientMessage msg st
                    Right t -> do
                        let tmpLines = T.lines t
                        return $ st & cmdLine.editContentsL .~ (Z.textZipper tmpLines Nothing)
                                    & csEditState.cedMultiline .~ (length tmpLines > 1)
            Sys.ExitFailure _ -> return st

toggleMessagePreview :: ChatState -> ChatState
toggleMessagePreview = csShowMessagePreview %~ not

addUserToCurrentChannel :: T.Text -> ChatState -> EventM Name ChatState
addUserToCurrentChannel uname st = do
    -- First: is this a valid username?
    let results = filter ((== uname) . _uiName . snd) $ HM.toList $ st^.usrMap
    case results of
        [(uid, _)] -> do
            liftIO $ doAsyncWith st $ do
                let cId = st^.csCurrentChannelId
                tryMM (void $ mmChannelAddUser (st^.csConn) (st^.csTok) (st^.csMyTeam.teamIdL) cId uid)
                      (const $ return return)
            return st
        _ -> do
            postErrorMessage ("No such user: " <> uname) st

handlePaste :: BS.ByteString -> ChatState -> ChatState
handlePaste bytes st = do
  let pasteStr = T.pack (UTF8.toString bytes)
      st' = st & cmdLine %~ applyEdit (Z.insertMany pasteStr)
  case length (getEditContents $ st'^.cmdLine) > 1 of
      True -> startMultilineEditing st'
      False -> st'

editingPermitted :: ChatState -> Bool
editingPermitted st =
    (length (getEditContents $ st^.cmdLine) == 1) ||
    st^.csEditState.cedMultiline

handleEditingInput :: Event -> ChatState -> EventM Name ChatState
handleEditingInput e st = do
    -- Only handle input events to the editor if we permit editing:
    -- if multiline mode is off, or if there is only one line of text
    -- in the editor. This means we skip input this catch-all handler
    -- if we're *not* in multiline mode *and* there are multiple lines,
    -- i.e., we are showing the user the status message about the
    -- current editor state and editing is not permitted.

    let smartBacktick = st^.csResources.crConfiguration.to configSmartBacktick
        smartChars = "*`_"
    st' <- case e of
        EvKey (KChar 't') [MCtrl] | editingPermitted st ->
            return $ st & cmdLine %~ applyEdit Z.transposeChars

        -- Not editing; backspace here means cancel multi-line message
        -- composition
        EvKey KBS [] | (not $ editingPermitted st) ->
            return $ st & cmdLine %~ applyEdit Z.clearZipper

        -- Backspace in editing mode with smart pair insertion means
        -- smart pair removal when possible
        EvKey KBS [] | editingPermitted st && smartBacktick ->
            let backspace = return $ st & cmdLine %~ applyEdit Z.deletePrevChar
            in case cursorAtOneOf smartChars (st^.cmdLine) of
                Nothing -> backspace
                Just ch ->
                    -- Smart char removal:
                    if | (cursorAtChar ch $ applyEdit Z.moveLeft $ st^.cmdLine) &&
                         (cursorIsAtEnd $ applyEdit Z.moveRight $ st^.cmdLine) ->
                           return $ st & cmdLine %~ applyEdit (Z.deleteChar >>> Z.deletePrevChar)
                       | otherwise -> backspace

        EvKey (KChar ch) [] | editingPermitted st && smartBacktick && ch `elem` smartChars ->
            -- Smart char insertion:
            let doInsertChar = return $ st & cmdLine %~ applyEdit (Z.insertChar ch)
            in if | (editorEmpty $ st^.cmdLine) ||
                       ((cursorAtChar ' ' (applyEdit Z.moveLeft $ st^.cmdLine)) &&
                        (cursorIsAtEnd $ st^.cmdLine)) ->
                      return $ st & cmdLine %~ applyEdit (Z.insertMany (T.pack $ ch:ch:[]) >>> Z.moveLeft)
                  | (cursorAtChar ch $ st^.cmdLine) &&
                    (cursorIsAtEnd $ applyEdit Z.moveRight $ st^.cmdLine) ->
                      return $ st & cmdLine %~ applyEdit Z.moveRight
                  | otherwise -> doInsertChar

        EvKey (KChar 'f') [MCtrl] | editingPermitted st ->
            return $ st & cmdLine %~ applyEdit Z.moveRight

        EvKey (KChar 'b') [MCtrl] | editingPermitted st ->
            return $ st & cmdLine %~ applyEdit Z.moveLeft

        EvKey (KChar 'f') [MMeta] | editingPermitted st ->
            return $ st & cmdLine %~ applyEdit Z.moveWordRight

        EvKey (KChar 'b') [MMeta] | editingPermitted st ->
            return $ st & cmdLine %~ applyEdit Z.moveWordLeft

        EvKey (KBS) [MMeta] | editingPermitted st ->
            return $ st & cmdLine %~ applyEdit Z.deletePrevWord

        EvKey (KChar 'd') [MMeta] | editingPermitted st ->
            return $ st & cmdLine %~ applyEdit Z.deleteWord

        EvKey (KChar 'k') [MCtrl] | editingPermitted st -> do
            let z = st^.cmdLine.editContentsL
                restOfLine = Z.currentLine (Z.killToBOL z)
                st' = st & csEditState.cedYankBuffer .~ restOfLine
            return $ st' & cmdLine %~ applyEdit Z.killToEOL

        EvKey (KChar 'y') [MCtrl] | editingPermitted st -> do
            let buf = st^.csEditState.cedYankBuffer
            return $ st & cmdLine %~ applyEdit (Z.insertMany buf)

        _ | editingPermitted st -> handleEventLensed st cmdLine handleEditorEvent e
          | otherwise -> return st

    return $ st' & csCurrentCompletion .~ Nothing

editorEmpty :: Editor T.Text a -> Bool
editorEmpty e = cursorIsAtEnd e &&
                cursorIsAtBeginning e

cursorIsAtEnd :: Editor T.Text a -> Bool
cursorIsAtEnd e =
    let col = snd $ Z.cursorPosition z
        curLine = Z.currentLine z
        z = e^.editContentsL
    in col == T.length curLine

cursorIsAtBeginning :: Editor T.Text a -> Bool
cursorIsAtBeginning e =
    let col = snd $ Z.cursorPosition z
        z = e^.editContentsL
    in col == 0

cursorAtOneOf :: [Char] -> Editor T.Text a -> Maybe Char
cursorAtOneOf [] _ = Nothing
cursorAtOneOf (c:cs) e =
    if cursorAtChar c e
    then Just c
    else cursorAtOneOf cs e

cursorAtChar :: Char -> Editor T.Text a -> Bool
cursorAtChar ch e =
    let col = snd $ Z.cursorPosition z
        curLine = Z.currentLine z
        z = e^.editContentsL
    in (T.singleton ch) `T.isPrefixOf` T.drop col curLine
