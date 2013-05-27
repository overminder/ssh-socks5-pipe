{-# LANGUAGE RecordWildCards #-}

module Message where

import Control.Applicative
import Data.Binary
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.Int

data Message
  = Connect {
    connId :: !Int,
    connHost :: !(Either Int String), -- ipv4 addr or hostname.
    connPort :: !Int
  }
  | ConnectResult {
    connId :: !Int,
    connSucc :: !Bool,
    connUsingHostPort :: Maybe (Int, Int)
  }
  | WriteTo {
    connId :: !Int,
    writeContent :: !B.ByteString
  }
  | Disconnect {
    connId :: !Int
  }
  deriving (Show, Eq)

isConnect (Connect {}) = True
isConnect _ = False

-- XXX: derive generic instead?
instance Binary Message where
  put (Connect {..})
    = put (0 :: Word8) *> put connId *> put connHost *> put connPort
  put (ConnectResult {..})
    = put (1 :: Word8) *> put connId *>
      put connSucc *> put connUsingHostPort
  put (WriteTo {..})
    = put (2 :: Word8) *> put connId *> put writeContent
  put (Disconnect {..})
    = put (3 :: Word8) *> put connId
  get = do
    i <- get :: Get Word8
    case i of
      0 -> Connect <$> get <*> get <*> get
      1 -> ConnectResult <$> get <*> get <*> get
      2 -> WriteTo <$> get <*> get
      3 -> Disconnect <$> get

serialize :: Message -> BL.ByteString
serialize msg = len `BL.append` lbs
  where
    lbs = encode msg
    len = encode (BL.length lbs)

deserialize :: BL.ByteString -> (BL.ByteString, [Message])
deserialize bs
  | BL.length bs < headerLen = (bs, [])
  | otherwise = go (decode (BL.take headerLen bs)) (BL.drop headerLen bs) bs
  where
    go :: Int64 -> BL.ByteString -> BL.ByteString -> (BL.ByteString, [Message])
    go len rest bs
      | BL.length rest < len = (bs, [])
      | otherwise = let (bs', msgs) = deserialize (BL.drop len rest)
                     in (bs', decode (BL.take len rest) : msgs)

    headerLen = BL.length (encode (0 :: Int64))
  
