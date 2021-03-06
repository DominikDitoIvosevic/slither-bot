{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module SlitherBot.Proxy (proxy) where

import           ClassyPrelude
import qualified Network.WebSockets  as WS
import           Network.URI (parseURI, URI(..), URIAuth(..))
import qualified Data.ByteString.Char8 as BSC8
import qualified Network.Wai.Handler.WebSockets as WS
import qualified Network.Wai.Handler.Warp as Warp
import qualified Network.Wai as Wai
import qualified Network.HTTP.Types as Http
import qualified Lucid
import           Control.Exception.Safe (tryAny)
import           Data.Void (absurd)

import           SlitherBot.Ai
import           SlitherBot.Ai.Avoid
import           SlitherBot.Protocol
import           SlitherBot.GameState

-- Path: 
proxy :: Int -> IO ()
proxy serverPort = do
  aiStateVar <- newTVarIO (aiInitialState ai)
  Warp.run serverPort (WS.websocketsOr WS.defaultConnectionOptions (wsApp aiStateVar) (backupApp aiStateVar))
  where
    ai = avoidAi

    wsApp aiStateVar pendingConn = do
      let reqHead = WS.pendingRequest pendingConn
      let couldNotParseURI = do
            WS.rejectRequest pendingConn "Could not parse URI"
      Just host0 <- return (BSC8.unpack <$> lookup "Host" (WS.requestHeaders reqHead))
      let (host, ':' : portString) = break (== ':') host0
      let path = BSC8.unpack (WS.requestPath reqHead)
      clientConn <- WS.acceptRequest pendingConn
      port <- case readMay portString of
        Nothing -> fail ("Could not read port from " ++ show portString)
        Just port -> return port

      -- strip the Sec-WebSocket-Key header
      let headers = filter (\( header, _ ) -> header /= "Sec-WebSocket-Key") (WS.requestHeaders reqHead)

      gameStateVar <- newMVar defaultGameState

      -- make the equivalent connection to the server
      exc <- tryAny $ WS.runClientWith host port path WS.defaultConnectionOptions headers $ \serverConn -> do
        let
          clientToServer = do
            -- forward first message
            firstMessageBs <- WS.receiveData clientConn
            WS.sendBinaryData serverConn (firstMessageBs :: ByteString)

            let
              clientServerLoop = forever $ do
                -- putStrLn "Sending data..."
                messageBs :: ByteString <- WS.receiveData clientConn
                WS.sendBinaryData serverConn messageBs
            fmap (either id id) (race (aiLoop Nothing) clientServerLoop)

          aiLoop mbPrevOutput = do
            gameState <- readMVar gameStateVar
            output <- atomically $ do
              state <- readTVar aiStateVar
              let (output, nextState) = aiUpdate ai gameState state
              writeTVar aiStateVar nextState
              return output
            when ((aoAngle <$> mbPrevOutput) /= Just (aoAngle output)) $
              WS.sendBinaryData serverConn (serializeClientMessage (SetAngle (aoAngle output)))
            case (aoSpeedup <$> mbPrevOutput, aoSpeedup output) of
              (Nothing, False) -> return ()
              (Just x, y) -> when (x /= y) $ do
                let msg = if aoSpeedup output then EnterSpeed else LeaveSpeed
                WS.sendBinaryData serverConn (serializeClientMessage msg)
              (Nothing, True) -> do
                WS.sendBinaryData serverConn (serializeClientMessage EnterSpeed)
            threadDelay (250 * 1000)
            aiLoop (Just output)

          serverToClient = forever $ do
            msg <- WS.receiveData serverConn
            WS.sendBinaryData clientConn msg
            modifyMVar_ gameStateVar $ \gameState -> do
              case parseServerMessage msg of
                Left err -> do
                  putStrLn $ "Couldn't parse " ++ tshow msg ++ ": " ++ pack err
                  return gameState
                Right serverMsg -> do
                  putStrLn ("SERVER " ++ tshow serverMsg)
                  case updateGameState gameState serverMsg of
                    Left err -> fail ("Couldn't update game state: " ++ err)
                    Right Nothing -> return gameState
                    Right (Just gameState') -> return gameState'
        fmap (either id id) (race clientToServer serverToClient)
      case exc of
        Left exc' -> do
          putStrLn ("EXCEPTION quitting " ++ tshow exc')
        Right x -> absurd x

    backupApp aiStateVar _req cont = do
      aiState <- atomically (readTVar aiStateVar)
      let statusHtml = do
            Lucid.html_ $ do
              Lucid.body_ $ do
                aiHtmlStatus ai aiState
                Lucid.script_ "setTimeout(function() { location.reload(); }, 250)"
      cont (Wai.responseLBS Http.status200 [] (Lucid.renderBS statusHtml))
