module Compat where

import Control.Applicative
import Control.Concurrent
import Control.Exception
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC8
import Network.Socket
import Network.BSD
import System.IO

mkReusableSock = do
  proto <- getProtocolNumber "tcp"
  sock <- socket AF_INET Stream proto
  setSocketOption sock ReuseAddr 1
  return sock

mkListeningSock port = do
  sock <- mkReusableSock
  bindSocket sock (SockAddrInet port iNADDR_ANY)
  listen sock 5
  return sock

hGetByte :: Num a => Handle -> IO a
hGetByte h = fromIntegral . B.head <$> B.hGet h 1

hGetSome :: Handle -> Int -> IO B.ByteString
hGetSome hh i
    | i >  0    = let
                   loop = do
                     s <- B.hGetNonBlocking hh i
                     if not (B.null s)
                        then return s
                        else do eof <- hIsEOF hh
                                if eof then return s
                                       else hWaitForInput hh (-1) >> loop
                                         -- for this to work correctly, the
                                         -- Handle should be in binary mode
                                         -- (see GHC ticket #3808)
                  in loop
    | i == 0    = return B.empty

catchEx :: Exception e => IO a -> (e -> IO a) -> IO a
catchEx = Control.Exception.catch

decodeAscii :: B.ByteString -> String
decodeAscii = BC8.unpack

mkIdempotent m = do
  lock <- newMVar m
  return $ do
    m <- swapMVar lock (return ())
    m

split :: Eq a => a -> [a] -> [[a]]
split x xs = case back of
  [] -> [front]
  _:rest -> front : split x rest
  where
    (front, back) = break (== x) xs

waitForCallable m = do
  ref <- newEmptyMVar
  let
    callRef = do
      f <- takeMVar ref
      f
  m (putMVar ref)
  callRef

