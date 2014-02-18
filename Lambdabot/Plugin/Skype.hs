module Lambdabot.Plugin.Skype where

import Control.Applicative
import Control.Concurrent.Lifted (fork)
import Control.Concurrent.STM.TChan (readTChan)
import Control.Monad (unless, void)
import Control.Monad.Reader (ReaderT, runReaderT)
import Control.Monad.STM (atomically)
import Control.Monad.Trans (lift, liftIO)
import Data.List.Split (splitOn)
import Lambdabot.IRC (IrcMessage(..))
import Lambdabot.Monad (received, addServer)
import Lambdabot.Plugin
import Web.Skype.API
import Web.Skype.Command.Misc
import Web.Skype.Core
import Web.Skype.Protocol

import qualified Data.ByteString.Char8 as BC
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Web.Skype.Command.Chat as Chat
import qualified Web.Skype.Command.ChatMessage as ChatMessage
import qualified Web.Skype.Command.User as User

skypePlugin :: Module (Maybe SkypeConnection)
skypePlugin = newModule
  { moduleDefState = return Nothing
  , moduleCmds = return
    [ (command "skype")
        { help = say "skype [chatID..]"
        , privileged = True
        , process = skypeCommand
        }
    ]
  }

skypePlugins :: [String]
skypePlugins = ["skype"]

skypeCommand :: String -> Cmd (ModuleT (Maybe SkypeConnection) LB) ()
skypeCommand args = do
  connection <- getConnection

  unless (null args) $
    mapM_ (registerChat connection . BC.pack) $ splitOn " " args

registerChat :: (MonadSkype (ReaderT connection IO))
             => connection
             -> ChatID
             -> Cmd (ModuleT (Maybe SkypeConnection) LB) ()
registerChat connection chatID = do
  resultForGetTopic <- liftIO $ runSkype connection $ Chat.getTopic chatID

  case resultForGetTopic of
    Right topic -> do
      lift $ addServer (BC.unpack chatID) $ messageSender connection
      say $ "Added to \"" ++ (T.unpack topic) ++ "\" chat."

    Left _ -> say $ "Failed to add chat: " ++ (BC.unpack chatID)

getConnection :: Cmd (ModuleT (Maybe SkypeConnection) LB) SkypeConnection
getConnection = withMS connector
  where
    connector (Just connection) _ = return connection
    connector Nothing writer = do
      connection <- liftIO $ connect "lambdabot"
      runSkype connection $ protocol 9999
      lift $ lift $ fork $ messageListener connection
      writer $ Just connection
      return connection

messageSender :: (MonadSkype (ReaderT connection IO))
              => connection
              -> IrcMessage
              -> LB ()
messageSender connection message = do
  void $ liftIO $ runSkype connection $ Chat.sendMessage chatID messageBody
  where
    chatID = BC.pack $ ircMsgServer message
    messageBody = T.decodeUtf8 . BC.pack . tail . head . tail $ ircMsgParams message

messageListener :: (MonadSkype (ReaderT connection IO))
                => connection
                -> LB ()
messageListener connection =
  loop =<< liftIO (runReaderT dupNotificationChan connection)
  where
    loop notificationChan = do
      notification <- liftIO $ atomically $ readTChan notificationChan

      case parseNotification notification of
        Just (ChatMessage messageID (ChatMessageStatus ChatMessageStatusReceive)) -> do
          result <- liftIO $ runSkype connection $
            (,,,) <$> User.getCurrentUserHandle
                  <*> ChatMessage.getSender messageID
                  <*> ChatMessage.getChat messageID
                  <*> ChatMessage.getBody messageID

          case result of
            Right (from, to, chat, body) -> do
              received $ IrcMessage
                { ircMsgServer  = BC.unpack chat
                , ircMsgLBName  = BC.unpack from
                , ircMsgPrefix  = BC.unpack to
                , ircMsgCommand = "PRIVMSG"
                , ircMsgParams  = [BC.unpack to, ':' : BC.unpack (T.encodeUtf8 body)]
                }
            Left _ -> loop notificationChan
        _ -> loop notificationChan

      loop notificationChan
