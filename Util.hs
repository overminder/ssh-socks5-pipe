module Util where

import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Network.Socket
import Network.BSD

toStrict :: BL.ByteString -> B.ByteString
toStrict = B.concat . BL.toChunks

toLazy :: B.ByteString -> BL.ByteString
toLazy = BL.pack . B.unpack

mkReusableSock = do
  proto <- getProtocolNumber "tcp"
  sock <- socket AF_INET Stream proto
  setSocketOption sock ReuseAddr 1
  return sock
