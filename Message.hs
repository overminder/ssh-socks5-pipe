{-# LANGUAGE RecordWildCards, ScopedTypeVariables #-}

module Message where

import Control.Applicative
import qualified Data.ByteString as B
import Data.Serialize
import Data.Word
import qualified Data.List as L
import Network.Socket
import Network.BSD

-- High-level protocol definition: Message and FwdOption

data FwdOption
  = FwdLocal {
    fwdListenPort :: !PortNumber,
    fwdConnectHost :: !HostName,
    fwdConnectPort :: !PortNumber
  }
  | FwdRemote {
    fwdListenPort :: !PortNumber,
    fwdConnectHost :: !HostName,
    fwdConnectPort :: !PortNumber
  }
  | FwdLocalDynamic {
    fwdListenPort :: !PortNumber
  }
  | FwdRemoteDynamic {
    fwdListenPort :: !PortNumber
  }
  deriving (Show, Eq)

-- Ipv4 addr or hostname (a string).
type ConnHost = Either HostAddress HostName

data Message
  = Connect {
    connId :: !Int,
    connHost :: !ConnHost,
    connPort :: !PortNumber
  }
  | ConnectResult {
    connId :: !Int,
    connSucc :: !Bool,
    connUsingHostPort :: Maybe (HostAddress, PortNumber)
  }
  | WriteTo {
    connId :: !Int,
    writeContent :: !B.ByteString
  }
  | Disconnect {
    connId :: !Int
  }
  | HandShake {
    shakeFwdOpt :: !FwdOption
  }
  deriving (Show, Eq)

isConnectMessage :: Message -> Bool
isConnectMessage (Connect {}) = True
isConnectMessage _            = False

-- Need to manually define the methods, since cslab2 only has ghc 6.10.4
-- so we could not use DeriveGeneric
instance Serialize PortNumber where
  put (PortNum i) = put i
  get = PortNum <$> get

instance Serialize FwdOption where
  put (FwdLocal {..})
    = put (0 :: Word8) *> put fwdListenPort *>
      put fwdConnectHost *> put fwdConnectPort
  put (FwdRemote {..})
    = put (1 :: Word8) *> put fwdListenPort *>
      put fwdConnectHost *> put fwdConnectPort
  put (FwdLocalDynamic {..})
    = put (2 :: Word8) *> put fwdListenPort
  put (FwdRemoteDynamic {..})
    = put (3 :: Word8) *> put fwdListenPort

  get = do
    tag <- get :: Get Word8
    case tag of
      0 -> FwdLocal <$> get <*> get <*> get
      1 -> FwdRemote <$> get <*> get <*> get
      2 -> FwdLocalDynamic <$> get
      3 -> FwdRemoteDynamic <$> get

instance Serialize Message where
  put (Connect {..})
    = put (0 :: Word8) *> put connId *> put connHost *> put connPort
  put (ConnectResult {..})
    = put (1 :: Word8) *> put connId *>
      put connSucc *> put connUsingHostPort
  put (WriteTo {..})
    = put (2 :: Word8) *> put connId *> put writeContent
  put (Disconnect {..})
    = put (3 :: Word8) *> put connId
  put (HandShake {..})
    = put (4 :: Word8) *> put shakeFwdOpt
  get = do
    tag <- get :: Get Word8
    case tag of
      0 -> Connect <$> get <*> get <*> get
      1 -> ConnectResult <$> get <*> get <*> get
      2 -> WriteTo <$> get <*> get
      3 -> Disconnect <$> get
      4 -> HandShake <$> get

packNetStr :: Serialize a => a -> B.ByteString
packNetStr msg = len `B.append` bs
  where
    bs = encode msg
    len = encode (B.length bs)

-- XXX: sharing of bytestring could consume lots of memory?
unpackNetStr :: Serialize a => B.ByteString -> (B.ByteString, [a])
unpackNetStr bs
  | B.length bs < headerLen = (bs, [])
  | otherwise = go (decodeRight (B.take headerLen bs)) (B.drop headerLen bs) bs
  where
    go :: Serialize a => Int -> B.ByteString ->
                         B.ByteString -> (B.ByteString, [a])
    go len rest bs
      | B.length rest < len = (bs, [])
      | otherwise = let (bs', as) = unpackNetStr (B.drop len rest)
                        a = decodeRight (B.take len rest)
                     in (bs', a:as)

    headerLen = B.length (encode (0 :: Int))

    decodeRight bs = case decode bs of
      Left s -> error $ "unpackNetStr: " ++ s
      Right x -> x

-- A pure version of ntoa
ntoa :: HostAddress -> String
ntoa addr = L.intercalate "." $ map show bytes
  where
    bytes = B.unpack $ encode addr

pprHostPort :: ConnHost -> PortNumber -> String
pprHostPort host port = hostName ++ ":" ++ show port
  where
    hostName = case host of
      Left ipv4Addr -> ntoa ipv4Addr
      Right name -> name

