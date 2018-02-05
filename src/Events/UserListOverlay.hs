module Events.UserListOverlay where

import Control.Monad (when)
import qualified Graphics.Vty as Vty

import Brick.Widgets.Edit (handleEditorEvent)

import Types
import Events.Keybindings
import State.UserListOverlay

onEventUserListOverlay :: Vty.Event -> MH ()
onEventUserListOverlay =
  handleKeyboardEvent userListOverlayKeybindings $ \e -> do
      -- Get the editor content before the event.
      before <- userListSearchString

      -- Handle the editor input event.
      mhHandleEventLensed (csUserListOverlay.userListSearchInput) handleEditorEvent e

      -- Get the editor content after the event. If the string changed,
      -- start a new search.
      after <- userListSearchString

      when (before /= after) $
          resetUserListSearch after

-- | The keybindings we want to use while viewing a user list overlay
userListOverlayKeybindings :: KeyConfig -> [Keybinding]
userListOverlayKeybindings = mkKeybindings
  [ mkKb CancelEvent "Exit user browsing" exitUserListMode
  , mkKb SelectUpEvent "Select the previous user" userListSelectUp
  , mkKb SelectDownEvent "Select the next user" userListSelectDown
  , mkKb PageDownEvent "Page down in the user list" userListPageDown
  , mkKb PageUpEvent "Page up in the user list" userListPageUp
  ]
