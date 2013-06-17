import Network
import System.IO
import Data.Char --for ord
import System.Random -- for randon nonce
import Data.Time.Clock.POSIX -- unix time
import Data.Default

import qualified Data.Enumerator as E
import qualified Data.Enumerator.Binary as EB

import Control.Monad
import Control.Monad.State
import Control.Monad.IO.Class
import Control.Monad.Trans.Resource

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC

import qualified Database.LevelDB as DB

import Bitcoin.Message
import Bitcoin.Protocol.VarString
import Bitcoin.Protocol.NetworkAddress
import Bitcoin.Protocol.Ping
import Bitcoin.Protocol.Tx
import Bitcoin.Protocol.Inv
import Bitcoin.Protocol.GetData
import Bitcoin.Protocol.Block

import qualified Bitcoin.LevelDB as DB
import qualified Bitcoin.Constants as Const

import qualified Text.Show.Pretty as Pr

type Application = Message -> DB.BlockChainIO (Maybe Message)

main :: IO ()
main = withSocketsDo . DB.runResourceT $ do
    db <- DB.getHandle
    h <- liftIO $ do 
        h <- connectTo "127.0.0.1" (PortNumber 18333)
        hSetBuffering h LineBuffering
        sendVersion h
        return h
    E.run_ $ (EB.enumHandle 1024 h) E.$$ mainLoop db h

mainLoop :: DB.DB -> Handle -> E.Iteratee BS.ByteString (ResourceT IO) ()
mainLoop db h = do
    msg <- iterMessage 
    res <- lift $ evalStateT (runApp msg) db
    case res of
        Just r -> E.run_ $ (enumMessage r) E.$$ (EB.iterHandle h)
        _      -> return ()
    mainLoop db h

runApp :: Application
runApp msg = do
    liftIO $ putStrLn $ Pr.ppShow msg
    return $ case msg of
        MVersion _ -> Just MVerAck
        --MVerAck -> MGetAddr
        MPing (Ping n) -> Just $ MPong (Pong n)
        MInv (Inv l) -> Just $ MGetData (GetData l)
        _ -> Nothing

sendVersion :: Handle -> IO ()
sendVersion h = do
    let zeroAddr = 0xffff00000000
        addr = NetworkAddress 1 zeroAddr 0
        ua = VarString $ BS.pack $ map (fromIntegral . ord) "/haskoin:0.0.1/"
    time <- getPOSIXTime
    rdmn <- randomIO -- nonce
    let vers = Version 70001 1 (floor time) addr addr rdmn ua 0 False
    E.run_ $ (enumMessage $ MVersion vers) E.$$ (EB.iterHandle h)

checkTransaction :: Tx -> Bool
checkTransaction tx = case tx of
    (Tx _ [] _ _) -> False --vin False
    (Tx _ _ [] _) -> False --vout False
    _ -> not $ getSerializeSize (MTx tx) > Const.maxBlockSize
    
