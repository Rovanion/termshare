{-#LANGUAGE TemplateHaskell #-}
{-#LANGUAGE OverloadedStrings #-}
module Main
where

import System.Environment
import Network.WebSockets
import Network.Wai
import Network.Wai.Handler.WebSockets
import Network.Wai.Handler.Warp as Warp
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Control.Concurrent.Chan
import Control.Concurrent
import Data.FileEmbed
import Control.Monad
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Lazy.UTF8 as LUTF8
import Network.HTTP.Types
import Data.Monoid
import Control.Exception
import Control.Concurrent.Async

getString :: IO Text
getString =
  go ""
  where
    go "" = do
      -- block until we've seen at least 1 character
      c <- getChar
      go $ Text.singleton c
    go txt
      | Text.length txt >= 800 =
          -- when text gets too long, send and clear the queue
          return txt
      | otherwise = do
          -- try to read a character, but give up after 10 ms
          cEither <- race
                (threadDelay 10000 >> return ())
                getChar
          case cEither of
            Left () ->
              -- Didn't receive anything within 10 ms: send and clear.
              return txt
            Right '\n' ->
              -- Also send & clear after a newline.
              return $ Text.snoc txt '\n'
            Right c ->
              -- Otherwise, append and keep going.
              go (Text.snoc txt c)


main = do
  feed <- newChan :: IO (Chan Text)
  history <- newMVar [] :: IO (MVar [Text])

  forkIO . forever $ do
    str <- getString
    when
      (str /= "")
      (writeChan feed str)
  forkIO . forever $ do
    ln <- readChan feed
    t <- takeMVar history
    let t' = ln:t
    putMVar history t'
  Warp.runEnv 5000 $ appMain history feed

appMain :: MVar [Text] -> Chan Text -> Application
appMain history feed rq respond = do
  case pathInfo rq of
    ["ws"] ->
      websocketsOr
        defaultConnectionOptions
        (appWS history feed)
        (error "not a WS request")
        rq
        respond
    _ -> case requestMethod rq of
      "GET" -> do
        case pathInfo rq of
          -- [] -> serve "text/html;charset=utf8" $ LBS.fromStrict $(embedFile "static/index.html")
          -- ["index.js"] -> serve "text/javascript" $ LBS.fromStrict $(embedFile "static/index.js")
          -- ["hterm_all.js"] -> serve "text/javascript" $ LBS.fromStrict $(embedFile "static/hterm_all.js")
          -- ["style.css"] -> serve "text/css" $ LBS.fromStrict $(embedFile "static/style.css")
          [] -> serveDyn "text/html;charset=utf8" "static/index.html"
          ["index.js"] -> serveDyn "text/javascript" "static/index.js"
          ["hterm_all.js"] -> serveDyn "text/javascript" "static/hterm_all.js"
          ["style.css"] -> serveDyn "text/css" "static/style.css"
          _ -> error "Not Found"
      _ -> error "Invalid method"
  where
    serve :: ByteString -> LBS.ByteString -> IO ResponseReceived
    serve contentType body =
      respond $
        responseLBS
          (mkStatus 200 "OK")
          [("Content-Type", contentType)]
          body

    serveDyn :: ByteString -> FilePath -> IO ResponseReceived
    serveDyn contentType fn =
      respond $
        responseFile
          (mkStatus 200 "OK")
          [("Content-Type", contentType)]
          fn
          Nothing

appWS history feedOrig pendingConn = do
  conn <- acceptRequest pendingConn
  forkPingThread conn 30
  putStrLn "Connected"
  hist <- takeMVar history
  feed <- dupChan feedOrig
  putMVar history hist

  -- Set window size
  geometryMay <- do
    linesMay <- lookupEnv "LINES"
    colsMay <- lookupEnv "COLUMNS"
    pure $ do
      cols <- colsMay
      lines <- linesMay
      pure $ cols ++ "x" ++ lines
  case geometryMay of
    Nothing ->
      pure ()
    Just geometry -> do
      sendTextData conn . Text.pack $ 'G' : geometry

  -- Send the last 100 lines of history
  sendTextDatas conn (map ("=" <>) . reverse $ take 100 hist)
  t <- forkIO . forever $ do
    ln <- readChan feed
    sendTextData conn ("=" <> ln)
  flip finally (disconnect t) . forever $ do
    receive conn >> pure ()
  where
    disconnect :: ThreadId -> IO ()
    disconnect t = do
      killThread t
      putStrLn "Disconnect"
