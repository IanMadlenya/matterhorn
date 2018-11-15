module State.Users
  ( handleNewUsers
  , handleTypingUser
  , handleNewUserDirect
  )
where

import           Prelude ()
import           Prelude.MH

import           Data.Time ( getCurrentTime )
import           Lens.Micro.Platform

import qualified Network.Mattermost.Endpoints as MM
import           Network.Mattermost.Types

import           Config
import           Types

import           State.Common


handleNewUsers :: Seq UserId -> MH () -> MH ()
handleNewUsers newUserIds after = do
    doAsyncMM Preempt getUserInfo addNewUsers
    where getUserInfo session _ =
              do nUsers <- MM.mmGetUsersByIds newUserIds session
                 let usrInfo u = userInfoFromUser u True
                     usrList = toList nUsers
                 return $ usrInfo <$> usrList

          addNewUsers :: [UserInfo] -> MH ()
          addNewUsers is = mapM_ addNewUser is >> after

-- | Handle the typing events from the websocket to show the currently
-- typing users on UI
handleTypingUser :: UserId -> ChannelId -> MH ()
handleTypingUser uId cId = do
  config <- use (csResources.crConfiguration)
  when (configShowTypingIndicator config) $ do
    ts <- liftIO getCurrentTime -- get time now
    csChannels %= modifyChannelById cId (addChannelTypingUser uId ts)

handleNewUserDirect :: User -> MH ()
handleNewUserDirect newUser = do
    let usrInfo = userInfoFromUser newUser True
    addNewUser usrInfo
