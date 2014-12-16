{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Ceilometer.Process(runPublisher, processSample, siphash) where

import           Control.Applicative
import           Control.Concurrent                 hiding (yield)
import           Control.Concurrent.STM
import           Control.Monad
import           Control.Monad.Reader
import           Control.Monad.State
import           Crypto.MAC.SipHash                 (SipHash (..), SipKey (..),
                                                     hash)
import           Data.Aeson
import           Data.Bits
import qualified Data.ByteString                    as S
import qualified Data.ByteString.Lazy.Char8         as L
import           Data.HashMap.Strict                (HashMap)
import qualified Data.HashMap.Strict                as H
import           Data.List
import           Data.Maybe
import           Data.Monoid
import           Data.Text                          (Text)
import qualified Data.Text                          as T
import qualified Data.Text.Encoding                 as T
import qualified Data.Text.IO                       as T
import           Data.Word
import           Network.AMQP
import           Options.Applicative                hiding (Success)
import           System.IO
import           System.Log.Logger

import           Marquise.Client
import           Vaultaire.Collector.Common.Process
import           Vaultaire.Collector.Common.Types

import           Ceilometer.Types

-- | Core entry point for Ceilometer.Process
--   Processes JSON objects from the configured queue and publishes
--   SimplePoints and SourceDicts to the vault
runPublisher :: IO ()
runPublisher = runCollectorP parseOptions initState cleanup queueSamples consumeSamples
  where
    parseOptions = CeilometerOptions
        <$> (T.pack <$> strOption
            (long "rabbit-login"
             <> short 'u'
             <> metavar "USERNAME"
             <> help "RabbitMQ username"))
        <*> (T.pack <$> strOption
            (long "rabbit-virtual-host"
             <> short 'r'
             <> metavar "VIRTUAL_HOSTNAME"
             <> value "/"
             <> help "RabbitMQ virtual host"))
        <*> strOption
            (long "rabbit-host"
             <> short 'h'
             <> metavar "HOSTNAME"
             <> help "RabbitMQ host")
        <*> switch
            (long "rabbit-ha"
             <> short 'a'
             <> help "Use highly available queues for RabbitMQ")
        <*> switch
            (long "rabbit-ssl"
            <> short 's'
            <> help "Use SSL for RabbitMQ")
        <*> (T.pack <$> strOption
            (long "rabbit-queue"
             <> short 'q'
             <> value "metering"
             <> metavar "QUEUE"
             <> help "RabbitMQ queue"))
        <*> option auto
            (long "poll-period"
             <> short 'p'
             <> value 5
             <> metavar "POLL-PERIOD"
             <> help "Time to wait (in seconds) before re-querying empty queue.")
        <*> strOption
            (long "password-file"
             <> short 'f'
             <> metavar "PASSWORD-FILE"
             <> help "File containing the password to use for RabbitMQ")
    initState (CommonOpts{..}, CeilometerOptions{..}) = do
        password <- withFile rabbitPasswordFile ReadMode T.hGetLine
        conn <- openConnection rabbitHost rabbitVHost rabbitLogin password
        infoM "Ceilometer.Process.initState" "Connected to RabbitMQ server"
        chan <- openChannel conn
        infoM "Ceilometer.Process.initState" "Opened channel"
        inChan <- atomically newTChan
        return $ CeilometerState conn chan inChan
    cleanup = do
        (_, CeilometerState conn _ _) <- get
        liftIO $ closeConnection conn
    queueSamples = do
        (_, CeilometerOptions{..}) <- ask
        (_, CeilometerState{..}) <- get
        forever $ do
            msg <- liftIO $ getMsg ceilometerMessageChan Ack rabbitQueue
            case msg of
                Nothing   -> liftIO $ do
                    infoM "Ceilometer.Process.publishSamples" $
                        "No message received, sleeping for " <> show rabbitPollPeriod <> " s"
                    threadDelay (1000000 * rabbitPollPeriod)
                Just msg' -> liftIO $ atomically $ writeTChan inChan msg'     
    consumeSamples = do
        (_, CeilometerOptions{..}) <- ask
        (_, CeilometerState{..}) <- get
        forever $ do
            (msg, env) <- liftIO $ atomically $ readTChan inChan
            tuples <- processSample $ msgBody msg
            forM_ tuples (\(addr, sd, ts, p) -> do
                collectSource addr sd
                collectSimple (SimplePoint addr ts p))
            liftIO $ ackEnv env

-- | Takes in a JSON Object and processes it into a list of
--   (Address, SourceDict, TimeStamp, Payload) tuples
processSample :: L.ByteString -> PublicationData
processSample bs =
    case eitherDecode bs of
        Left e             -> do
            liftIO $ alertM "Ceilometer.Process.processSample" $
                "Failed to parse: " <> L.unpack bs <> " Error: " <> e
            return []
        Right m -> process m

process :: Metric -> PublicationData
process m = process' (metricName m) (isEvent m)
  where
-- Supported metrics
    -- We process both instance pollsters and events
    process' "instance"                   False = processInstancePollster   m
    process' "instance"                   True  = processInstanceEvent      m
    process' "cpu"                        False = processBasePollster       m
    process' "disk.write.bytes"           False = processBasePollster       m
    process' "disk.read.bytes"            False = processBasePollster       m
    process' "network.incoming.bytes"     False = processBasePollster       m
    process' "network.outgoing.bytes"     False = processBasePollster       m
    process' "ip.floating"                True  = processIpEvent            m
    process' "volume.size"                True  = processVolumeEvent        m
    -- We process both image.size pollsters and events
    process' "image.size"                 False = processBasePollster       m
    process' "image.size"                 True  = processImageSizeEvent     m
    process' "snapshot.size"              True  = processSnapshotSizeEvent  m

    -- Ignored metrics
    -- Tracking both disk.r/w and disk.device.r/w will most likely double count
    process' x@"disk.device.write.bytes"    y       = ignore x y
    process' x@"disk.device.read.bytes"     y       = ignore x y
    -- We meter on bytes not requests
    process' x@"disk.write.requests"        y       = ignore x y
    process' x@"disk.read.requests"         y       = ignore x y
    process' x@"disk.device.write.requests" y       = ignore x y
    process' x@"disk.device.read.requests"  y       = ignore x y
    -- We derive these from instance pollsters
    process' x@"disk.ephemeral.size"        y@True  = ignore x y
    process' x@"disk.root.size"             y@True  = ignore x y
    process' x@"volume"                     y       = ignore x y
    process' x@"vcpus"                      y       = ignore x y
    process' x@"memory"                     y       = ignore x y
    -- We meter on bytes not packets
    process' x@"network.incoming.packets"   y       = ignore x y
    process' x@"network.outgoing.packets"   y       = ignore x y
    -- We use notifications over pollsters for ip-allocations
    process' x@"ip.floating"                y@False = ignore x y

    process' x@"ip.floating.create"         y       = ignore x y
    process' x@"ip.floating.update"         y       = ignore x y
    process' x@"ip.floating.delete"         y       = ignore x y
    -- These seem to be linked to constructing the stack, and are not common
    -- We potentially care about the network/disk I/O of these ops
    process' x@"image"                      y       = ignore x y
    process' x@"image.update"               y@True  = ignore x y
    process' x@"image.download"             y@True  = ignore x y
    process' x@"image.serve"                y@True  = ignore x y
    process' x@"image.upload"               y@True  = ignore x y
    process' x@"image.delete"               y@True  = ignore x y

    -- We care about ip allocations, these metrics are superfluous
    process' x@"port"                       y       = ignore x y
    process' x@"port.create"                y       = ignore x y
    process' x@"port.update"                y       = ignore x y
    process' x@"port.delete"                y       = ignore x y
    process' x@"network"                    y       = ignore x y
    process' x@"network.create"             y       = ignore x y
    process' x@"network.update"             y       = ignore x y
    process' x@"network.delete"             y       = ignore x y
    process' x@"subnet"                     y       = ignore x y
    process' x@"subnet.create"              y       = ignore x y
    process' x@"subnet.update"              y       = ignore x y
    process' x@"subnet.delete"              y       = ignore x y
    process' x@"router"                     y       = ignore x y
    process' x@"router.create"              y       = ignore x y
    process' x@"router.update"              y       = ignore x y
    process' x@"router.delete"              y       = ignore x y
    process' x@"snapshot"                   y       = ignore x y
    process' x@"network.services.firewall.policy" y = ignore x y

    process' x y
        | "instance:" `T.isPrefixOf` x = ignore x y
        | otherwise = alert x y
    ignore x y = do
        liftIO $ infoM "Ceilometer.Process.processSample" $
            "Ignored metric: " <> show x <> " event: " <> show y
        return []
    alert x y = do
        liftIO $ alertM "Ceilometer.Process.processSample" $
            "Unexpected metric: " <> show x <> " event: " <> show y <>
            "\n" <> show m
        return []

-- Utility

isEvent :: Metric -> Bool
isEvent m = H.member "event_type" $ metricMetadata m

getEventType :: Metric -> Maybe Text
getEventType m = case H.lookup "event_type" $ metricMetadata m of
    Just (String x) -> Just x
    _               -> Nothing

isCompound :: Metric -> Bool
isCompound m
    | isEvent m && metricName m == "ip.floating"   = True
    | isEvent m && metricName m == "volume.size"   = True
    | isEvent m && metricName m == "image.size"    = True
    | isEvent m && metricName m == "snapshot.size" = True
    | isEvent m && metricName m == "instance"      = True
    | otherwise                                    = False

-- | Constructs the internal HashMap of a SourceDict for the given Metric
--   Appropriately excludes optional fields when not present
getSourceMap :: Metric -> HashMap Text Text
getSourceMap m@Metric{..} =
    let base = [ ("_event", if isEvent m then "1" else "0")
               , ("_compound", if isCompound m then "1" else "0")
               , ("project_id",   metricProjectId)
               , ("resource_id",  metricResourceId)
               , ("metric_name",  metricName)
               , ("metric_unit",  metricUOM)
               , ("metric_type",  metricType)
               ]
        displayName = case H.lookup "display_name" metricMetadata of
            Just (String x) -> [("display_name", x)]
            _               -> []
        volumeType = case H.lookup "volume_type" metricMetadata of
            Just (String x) -> [("volume_type", x)]
            _               -> []
        counter = [("_counter", "1") | metricType == "cumulative"]
    in H.fromList $ counter <> base <> displayName <> volumeType

-- | Wrapped construction of a SourceDict with logging
mapToSourceDict :: HashMap Text Text -> IO (Maybe SourceDict)
mapToSourceDict sourceMap = case makeSourceDict sourceMap of
    Left err -> do
        alertM "Ceilometer.Process.getSourceDict" $
            "Failed to create sourcedict from " <> show sourceMap <> " error: " <> err
        return Nothing
    Right sd -> return $ Just sd

-- | Extracts the core identifying strings from the passed Metric
getIdElements :: Metric -> Text -> [Text]
getIdElements m@Metric{..} name =
    let base     = [metricProjectId, metricResourceId, metricUOM, metricType, name]
        event    = if isEvent m then
                       ["_event", fromJust $ getEventType m]
                   else []
        compound = ["_compound" | isCompound m]
    in concat [base,event,compound]

-- | Constructs a unique Address for a Metric from its identifying data
getAddress :: Metric -> Text -> Address
getAddress m name = hashIdentifier $ T.encodeUtf8 $ mconcat $ getIdElements m name

-- | Canonical siphash with key = 0
siphash :: S.ByteString -> Word64
siphash x = let (SipHash h) = hash (SipKey 0 0) x in h

-- Pollster based metrics

-- | Processes a pollster with no special requirements
processBasePollster :: Metric -> PublicationData
processBasePollster m@Metric{..} = do
    sd <- liftIO $ mapToSourceDict $ getSourceMap m
    case sd of
        Just sd' -> do
            let addr = getAddress m metricName
            return [(addr, sd', metricTimeStamp, metricPayload)]
        Nothing -> return []

-- | Extracts vcpu, ram, disk and flavor data from an instance pollster
--   Publishes each of these as their own metric with their own Address
processInstancePollster :: Metric -> PublicationData
processInstancePollster m@Metric{..} = do
    let baseMap = getSourceMap m --The sourcedict for the 4 metrics is mostly shared
    let names = ["instance_vcpus", "instance_ram", "instance_disk", "instance_flavor"]
    let uoms  = ["vcpu"          , "MB"          , "GB"           , "instance"       ]
    let addrs = map (getAddress m) names
    --Modify the metric-specific sourcedict fields
    let sourceMaps = map (\(name, uom) -> H.insert "metric_unit" uom
                                        $ H.insert "metric_name" name baseMap)
                         (zip names uoms)
    --Filter out any sourcedicts which failed to process
    --Each individual failure is logged in mapToSourceDict
    sds <- liftIO $ catMaybes <$> forM sourceMaps mapToSourceDict
    --Check if all 4 metrics' sourcedicts successully parsed
    if length sds == 4 then
        case fromJSON $ fromJust $ H.lookup "flavor" metricMetadata of
            Error e -> do
                liftIO $ alertM "Ceilometer.Process.processInstance" $
                    "Failed to parse flavor sub-object for instance pollster" <> show e
                return []
            Success Flavor{..} ->
                let (String instanceType) = fromJust $ H.lookup "instance_type" metricMetadata
                    instanceType' = siphash $ T.encodeUtf8 instanceType
                    diskTotal = instanceDisk + instanceEphemeral
                    payloads = [instanceVcpus, instanceRam, diskTotal, instanceType']
                in return (zip4 addrs sds (repeat metricTimeStamp) payloads)
    else do
        liftIO $ alertM "Ceilometer.Process.processInstance"
            "Failure to convert all sourceMaps to SourceDicts for instance pollster"
        return []

-- Event based metrics

processImageSizeEvent :: Metric -> PublicationData
processImageSizeEvent = processEvent getImagePayload

processInstanceEvent :: Metric -> PublicationData
processInstanceEvent m = return [] -- See https://github.com/anchor/vaultaire-collector-ceilometer/issues/4

processVolumeEvent :: Metric -> PublicationData
processVolumeEvent = processEvent getVolumePayload

processIpEvent :: Metric -> PublicationData
processIpEvent = processEvent getIpPayload

processSnapshotSizeEvent :: Metric -> PublicationData
processSnapshotSizeEvent = processEvent getSnapshotSizePayload

-- | Constructs the appropriate compound payload and vault data for an event
processEvent :: (Metric -> IO (Maybe Word64)) -> Metric -> PublicationData
processEvent f m@Metric{..} = do
    p  <- liftIO $ f m
    sd <- liftIO $ mapToSourceDict $ getSourceMap m
    let addr = getAddress m metricName
    return $ case (p, sd) of
        (Just compoundPayload, Just sd') ->
            [(addr, sd', metricTimeStamp, compoundPayload)]
        -- Sub functions will alert, alerts cause termination by default
        -- so this case should not be reached
        _ -> error $ "Impossible control flow reached in processEvent. Given: " ++ show m

-- | Constructs the compound payload for ip allocation events
getImagePayload :: Metric -> IO (Maybe Word64)
getImagePayload m@Metric{..} = do
    let _:verb:_ = T.splitOn "." $ fromJust $ getEventType m
    let (String status)  = fromJust $ H.lookup "status" metricMetadata
    statusValue <- case status of
        "active"  -> return 1
        "saving"  -> return 2
        "deleted" -> return 3
        x        -> do
            alertM "Ceilometer.Process.getImagePayload" $
                "Invalid status for image event: " <> show x
            return (-1)
    verbValue <- case verb of
        "serve"    -> return 1
        "update"   -> return 2
        "upload"   -> return 3
        "download" -> return 4
        "delete"   -> return 5
        x          -> do
            alertM "Ceilometer.Process.getImagePayload" $
                "Invalid verb for image event: " <> show x
            return (-1)
    let endpointValue = 0
    return $ if (-1) `elem` [statusValue, verbValue, endpointValue] then
        Nothing
    else
        Just $ constructCompoundPayload statusValue verbValue endpointValue ipRawPayload

-- | Constructs the compound payload for volume events
getVolumePayload :: Metric -> IO (Maybe Word64)
getVolumePayload m@Metric{..} = do
    let _:verb:endpoint:_ = T.splitOn "." $ fromJust $ getEventType m
    let (String status)  = fromJust $ H.lookup "status" metricMetadata
    statusValue <- case status of
        "error"     -> return 0
        "available" -> return 1
        "creating"  -> return 2
        "extending" -> return 3
        "deleting"  -> return 4
        "attaching" -> return 5
        "detaching" -> return 6
        "in-use"    -> return 7
        x           -> do
            alertM "Ceilometer.Process.getVolumePayload" $
                "Invalid status for volume event: " <> show x
            return (-1)
    verbValue <- case verb of
        "create" -> return 1
        "resize" -> return 2
        "delete" -> return 3
        "attach" -> return 4
        "detach" -> return 5
        x        -> do
            alertM "Ceilometer.Process.getVolumePayload" $
                "Invalid verb for volume event: " <> show x
            return (-1)
    endpointValue <- case endpoint of
        "start" -> return 1
        "end"   -> return 2
        x       -> do
            alertM "Ceilometer.Process.getVolumePayload" $
                "Invalid endpoint for volume event: " <> show x
            return (-1)
    return $ if (-1) `elem` [statusValue, verbValue, endpointValue] then
        Nothing
    else
        Just $ constructCompoundPayload statusValue verbValue endpointValue metricPayload

-- | An allocation has no 'value' per se, so we arbitarily use 1
ipRawPayload :: Word64
ipRawPayload = 1

-- | Constructs the compound payload for ip allocation events
getIpPayload :: Metric -> IO (Maybe Word64)
getIpPayload m@Metric{..} = do
    let _:verb:endpoint:_ = T.splitOn "." $ fromJust $ getEventType m
    let status = H.lookup "status" metricMetadata
    statusValue <- case status of
        Nothing                -> return 0
        Just Null              -> return 0
        Just (String "ACTIVE") -> return 1
        Just (String "DOWN")   -> return 2
        Just x                 -> do
            alertM "Ceilometer.Process.getIpPayload" $
                "Invalid status for ip event: " <> show x
            return (-1)
    verbValue <- case verb of
        "create" -> return 1
        "update" -> return 2
        "delete" -> return 3
        x        -> do
            alertM "Ceilometer.Process.getIpPayload" $
                "Invalid verb for ip event: " <> show x
            return (-1)
    endpointValue <- case endpoint of
        "start" -> return 1
        "end"   -> return 2
        x       -> do
            alertM "Ceilometer.Process.getIpPayload" $
                "Invalid endpoint for ip event: " <> show x
            return (-1)
    return $ if (-1) `elem` [statusValue, verbValue, endpointValue] then
        Nothing
    else
        Just $ constructCompoundPayload statusValue verbValue endpointValue ipRawPayload

-- | Constructs the compound payload for ip allocation events
getSnapshotSizePayload :: Metric -> IO (Maybe Word64)
getSnapshotSizePayload m@Metric{..} = do
    let _:verb:endpoint:_ = T.splitOn "." $ fromJust $ getEventType m
    let (String status)  = fromJust $ H.lookup "status" metricMetadata
    statusValue <- case status of
        "error"     -> return 0
        "available" -> return 1
        "creating"  -> return 2
        "deleting"  -> return 3
        x           -> do
            alertM "Ceilometer.Process.getSnapshotSizePayload" $
                "Invalid status for snapshot size event: " <> show x
            return (-1)
    verbValue <- case verb of
        "create" -> return 1
        "update" -> return 2
        "delete" -> return 3
        x        -> do
            alertM "Ceilometer.Process.getSnapshotSizePayload" $
                "Invalid verb for snapshot size event: " <> show x
            return (-1)
    endpointValue <- case endpoint of
        "start" -> return 1
        "end"   -> return 2
        x       -> do
            alertM "Ceilometer.Process.getSnapshotSizePayload" $
                "Invalid endpoint for snapshot size event: " <> show x
            return (-1)
    return $ if (-1) `elem` [statusValue, verbValue, endpointValue] then
        Nothing
    else
        Just $ constructCompoundPayload statusValue verbValue endpointValue metricPayload

-- | Constructs a compound payload from components
constructCompoundPayload :: Word64 -> Word64 -> Word64 -> Word64 -> Word64
constructCompoundPayload statusValue verbValue endpointValue rawPayload =
    let s = statusValue
        v = verbValue `shift` 8
        e = endpointValue `shift` 16
        r = 0 `shift` 24
        p = rawPayload `shift` 32
    in
        s + v + e + r + p
