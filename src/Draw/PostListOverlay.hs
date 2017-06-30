{-# LANGUAGE OverloadedStrings #-}

module Draw.PostListOverlay where

import           Prelude ()
import           Prelude.Compat

import           Control.Monad.Trans.Reader (withReaderT)
import qualified Data.Foldable as F
import           Data.Monoid ((<>))
import qualified Data.Text as T
import           Data.Time.Format ( formatTime
                                  , defaultTimeLocale )
import           Data.Time.LocalTime ( TimeZone, utcToLocalTime
                                     , localTimeToUTC, localDay
                                     , LocalTime(..), TimeOfDay(..) )
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import           Lens.Micro.Platform
import           Network.Mattermost
import           Network.Mattermost.Lenses

import Brick
import Brick.Widgets.Border
import Brick.Widgets.Center

import Themes
import Types
import Types.Channels
import Types.Posts
import Types.Messages
import Types.Users
import Draw.Main
import Draw.Util

hLimitWithPadding :: Int -> Widget n -> Widget n
hLimitWithPadding pad contents = Widget
  { hSize  = Fixed
  , vSize  = (vSize contents)
  , render =
      withReaderT (& availWidthL  %~ (\ n -> n - (2 * pad))) $ render $ cropToContext contents
  }

drawPostListOverlay :: PostListContents -> ChatState -> [Widget Name]
drawPostListOverlay contents st =
  drawPostsBox contents st : (forceAttr "invalid" <$> drawMain st)

insertDateHeaders :: T.Text -> TimeZone -> Messages -> Messages
insertDateHeaders datefmt tz ms = foldr addMessage ms dateT
    where dateT = fmap dateMsg dateRange
          dateRange = foldr checkDateChange [] ms
          checkDateChange m [] = [dayStart $ m^.mDate]
          checkDateChange m dl = if dayOf (head dl) == dayOf (m^.mDate)
                                 then dl
                                 else dayStart (m^.mDate) : dl
          dayOf = localDay . utcToLocalTime tz
          dayStart dt = localTimeToUTC tz $ LocalTime (dayOf dt) $ TimeOfDay 23 59 59
          dateMsg d = Message (getBlocks (T.pack $ formatTime defaultTimeLocale
                                          (T.unpack datefmt)
                                          (utcToLocalTime tz d)))
                      Nothing d (C DateTransition) False False
                      Seq.empty NotAReply Nothing mempty Nothing False

drawPostsBox :: PostListContents -> ChatState -> Widget Name
drawPostsBox contents st =
  centerLayer $ hLimitWithPadding 10 $ borderWithLabel (txt contentString) $ vBox $
    renderedMessageList ++ [fill ' ']
  where contentString = case contents of
          PostListFlagged -> "Flagged posts"
        uSet = Set.fromList (st^..csUsers.to allUsers.folded.uiName)
        cSet = Set.fromList (st^..csChannels.folded.ccInfo.cdName)
        messages = insertDateHeaders
                     (getDateFormat st)
                     (st^.timeZone)
                     (st^.csPostListOverlay.postListPosts)
        channelFor msg =
          let renderedMsg = renderSingleMessage st uSet cSet msg
          in case msg^.mOriginalPost of
            Just post
              | Just chan <- st^?csChannels.channelByIdL(post^.postChannelIdL) ->
                 case chan^.ccInfo.cdType of
                  Direct
                    | Just u <- findUserByDMChannelName (st^.csUsers)
                                                        (chan^.ccInfo.cdName)
                                                        (st^.csMe.userIdL) ->
                        (forceAttr channelNameAttr (txt (T.singleton '@' <> u^.uiName)) <=>
                          (str "  " <+> renderedMsg))
                  _ -> (forceAttr channelNameAttr (txt (chan^.ccInfo.to mkChannelName)) <=>
                         (str "  " <+> renderedMsg))
            _ | CP _ <- msg^.mType -> str "[BUG: unknown channel]"
              | otherwise -> renderedMsg

        renderedMessageList =
          let (s, (before, after)) = splitMessages (st^.csPostListOverlay.postListSelected) messages
          in case s of
            Nothing -> map channelFor (reverse (F.toList messages))
            Just curMsg ->
              [unsafeRenderMessageSelection (curMsg, (after, before)) channelFor]
