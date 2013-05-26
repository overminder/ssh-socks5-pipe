module Compat where

import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Network.Socket
import Network.BSD
import System.IO

toStrict :: BL.ByteString -> B.ByteString
toStrict = B.concat . BL.toChunks

toLazy :: B.ByteString -> BL.ByteString
toLazy = BL.pack . B.unpack

mkReusableSock = do
  proto <- getProtocolNumber "tcp"
  sock <- socket AF_INET Stream proto
  setSocketOption sock ReuseAddr 1
  return sock

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

