{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module SlitherBot.Proxy (proxy) where

import           ClassyPrelude
import qualified Network.WebSockets  as WS
import           Network.URI (parseURI, URI(..), URIAuth(..))
import qualified Data.ByteString.Char8 as BSC8
import           Control.Concurrent.Async (race)

import           SlitherBot.Protocol

proxy :: Int -> IO ()
proxy serverPort = WS.runServer "127.0.0.1" serverPort $ \pendingConn -> do
  let reqHead = WS.pendingRequest pendingConn
  case parseURI (BSC8.unpack (WS.requestPath reqHead)) of
    Just URI { uriPath = path, uriAuthority = Just URIAuth { uriRegName = host, uriPort = ':' : portString } } -> do
      putStrLn "Accepting request"
      print reqHead

      clientConn <- WS.acceptRequest pendingConn
      port <- case readMay portString of
        Nothing -> fail ("Could not read port from " ++ show portString)
        Just port -> return port

      -- strip the Sec-WebSocket-Key header
      let headers = filter (\( header, _ ) -> header /= "Sec-WebSocket-Key") (WS.requestHeaders reqHead)

      configVar <- newMVar defaultConfig

      -- make the equivalent connection to the server
      WS.runClientWith host port path WS.defaultConnectionOptions headers $ \serverConn -> do
        let clientToServer = forever $ do
              msg <- WS.receiveData clientConn
              WS.sendBinaryData serverConn (msg :: BSC8.ByteString)
        let serverToClient = forever $ do 
              msg <- WS.receiveData serverConn
              WS.sendBinaryData clientConn msg
              modifyMVar_ configVar $ \cfg -> do
                case parseServerMessage cfg msg of
                  Left err -> do
                    putStrLn $ "Couldn't parse " ++ tshow msg ++ ": " ++ pack err
                    return cfg
                  Right serverMsg -> do
                    print serverMsg
                    return $ case serverMsg of
                      Setup newCfg -> newCfg
                      _ -> cfg
        fmap (either id id) (race clientToServer serverToClient)
    Just _ -> WS.rejectRequest pendingConn "Could not parse URI"
    Nothing -> WS.rejectRequest pendingConn "Could not parse URI"