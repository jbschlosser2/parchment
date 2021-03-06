{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
module Main where

import Brick.AttrMap (attrMap)
import Brick.Main (App(..), customMain, showFirstCursor, halt, continue)
import Brick.Markup (markup)
import Brick.Types (Widget(..), Padding(..), Location(..), Next, EventM, BrickEvent(..),
                    getContext, Size(..), availHeightL, availWidthL)
import Brick.Widgets.Core ((<=>), padBottom, str, hBox, vBox, showCursor)
import Conduit
import Control.Concurrent (forkIO, newChan, writeChan)
import Control.Concurrent.Async (Concurrently(..), runConcurrently)
import Control.Concurrent.STM.TQueue
import Control.Monad (void)
import qualified Data.Aeson as JSON
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as BSL
import qualified Data.Conduit.List as CL
import Data.Conduit.Network
import Data.Conduit.TQueue (sourceTQueue)
import Data.Default
import qualified Data.HashMap.Lazy as HML
import Data.List (isPrefixOf)
import Data.List.Split (chunksOf)
import Data.Map (fromList)
import qualified Data.Map.Lazy as Map
import Data.Maybe (fromJust)
import Data.Scientific (floatingOrInteger)
import qualified Data.Sequence as S
import qualified Data.Text as TXT
import Data.Text.Markup ((@@))
import qualified Data.Vector as VEC
import Data.Word (Word8)
import qualified Graphics.Vty as V
import Language.Scheme.Core
import qualified Language.Scheme.Types as SCM
import Lens.Micro ((^.), (&), (.~), (^?), each)
import Network (withSocketsDo)
import Parchment.FString
import qualified Parchment.Indexed as I
import qualified Parchment.RingBuffer as RB
import Parchment.Session
import Parchment.Telnet
import Parchment.Util
import ScriptInterface
import System.Console.ArgParser
import System.Console.ArgParser.Format
import qualified System.Console.Terminal.Size as T
import System.Environment (getArgs)

data AppEvent = RecvEvent BS.ByteString

data AppArgs = AppArgs String Int deriving (Show)
argParser :: ParserSpec AppArgs
argParser = AppArgs
    `parsedBy` optPos "127.0.0.1" "hostname" `Descr` "Hostname of the MUD server"
    `andBy` optPos 4000 "port" `Descr` "Port of the MUD server"

withCorrectArgsDo :: (AppArgs -> IO ()) -> IO ()
withCorrectArgsDo app = do
    args <- getArgs
    interface <- (`setAppDescr` "Haskell MUD client") <$> mkApp argParser
    let parse_result = parseArgs args interface
    case parse_result of
         Left err -> putStrLn $ showCmdLineAppUsage defaultFormat interface ++ ['\n'] ++ err
         Right args -> app args

-- Main function.
main :: IO ()
main = withSocketsDo . withCorrectArgsDo $ \args -> do
    let AppArgs hostname port = args
    send_queue <- newTQueueIO
    event_chan <- newChan
    scmEnv <- r5rsEnv
    let settings = defaultSettings hostname port
    sess <- runIOMaybe . loadConfigAction $
        initialSession settings send_queue keyBindings scmEnv
    case sess of
         Nothing -> return ()
         Just sess -> do
            forkIO $ runTCPClient (clientSettings port (BSC.pack hostname)) $ \server ->
                void $ runConcurrently $ (,,)
                    <$> Concurrently (appSource server $$ chanSink event_chan
                                     chanWriteRecvEvent (return . const ()))
                    <*> Concurrently (sourceTQueue send_queue $$ appSink server)
            void . customMain (V.mkVty def) (Just event_chan) app $ sess
    where
        chanSink ch writer closer = do
            CL.mapM_ $ liftIO . writer ch
            liftIO $ closer ch
        chanWriteRecvEvent c s = writeChan c (RecvEvent s)

-- Application setup.
app :: App Sess AppEvent ()
app =
    App { appDraw = drawUI
        , appHandleEvent = handleEvent
        , appAttrMap = const $ attrMap V.defAttr []
        , appStartEvent = onAppStart
        , appChooseCursor = showFirstCursor
        }

-- Get initial number of lines available to the buffer during startup.
-- This info is needed for proper scrollback. Note that the number is updated
-- during every resize to remain correct.
onAppStart :: Sess -> EventM () Sess
onAppStart sess = do
    size <- liftIO T.size
    let lines = (T.height $ fromJust size) - nonBufferLines
    return $ sess & buffers . I.value . each . buffer . I.bounds_func .~ bufferBounds lines

-- Key bindings.
keyBindings = fromList $ map rawKeyBinding rawKeys ++
    [ ((V.EvKey V.KEsc []), halt)
    , ((V.EvKey V.KBS []), continue . backspaceInput)
    , ((V.EvKey V.KDel []), continue . deleteInput)
    , ((V.EvKey V.KEnter []), \sess -> do
        let input = getInput sess
        let new_sess = sess & historyNewest & clearInput
        liftAction (evalHook "send-hook" [SCM.String input]) new_sess)
    , ((V.EvKey V.KPageUp []), continue . pageUp)
    , ((V.EvKey V.KPageDown []), continue . pageDown)
    , ((V.EvKey V.KUp []), continue . historyOlder)
    , ((V.EvKey V.KDown []), continue . historyNewer)
    , ((V.EvKey V.KLeft []), continue . moveCursor (-1))
    , ((V.EvKey V.KRight []), continue . moveCursor 1)
    , ((V.EvKey (V.KChar 'u') [V.MCtrl]), continue . clearInput)
    ]
    where
        rawKeyBinding c = ((V.EvKey (V.KChar c) []), \st -> continue $ addInput c st)

-- Handle UI and other app events.
handleEvent :: Sess -> BrickEvent () AppEvent -> EventM () (Next Sess)
handleEvent sess (VtyEvent e) =
    case Map.lookup e (sess ^. bindings) of
        Just b -> b sess
        Nothing -> case e of
                        -- Update the number of buffer lines after the resize.
                        V.EvResize _ lines -> continue $
                            sess & buffers . I.value . each . buffer . I.bounds_func .~
                                bufferBounds (lines - nonBufferLines)
                        -- No binding was found.
                        _ -> continue $ sess & logInfo ("No binding found: " ++ show e)
handleEvent sess (AppEvent e) =
    case e of
        RecvEvent bs -> do
            -- Receive and process the server data.
            let sess2 = receiveServerData sess bs
            -- Extract received text and telnet commands.
            let recv_text = reverse $ sess2 ^. recv_state ^. text
            let telnets = sess2 ^. recv_state ^. telnet_cmds
            -- Reset received text and telnet commands for next time.
            let sess3 = sess2 & (recv_state . text) .~ []
                              & (recv_state . telnet_cmds) .~ []
            -- Write received text to the buffer.
            let sess4 = writeBuffer mainBufferNum recv_text sess3
            -- Call the recv hook.
            let clean = filter (not . (==) '\r') $ removeFormatting recv_text
            res <- liftIO . runIOMaybe $ evalHook "recv-hook" [SCM.String clean] sess4
            case res of
                Nothing -> halt sess4
                Just sess5 -> do
                    -- Handle telnet commands.
                    let handlers = map (handleTelnet . BS.unpack) telnets
                    sess6 <- liftIO . runIOMaybe $ (chainM handlers) sess5
                    case sess6 of
                        Nothing -> halt sess5
                        Just sess7 -> continue sess7
handleEvent sess _ = continue sess

handleTelnet :: [Word8] -> Sess -> IOMaybe Sess
handleTelnet cmd
    | cmd == [tIAC, tDO, tTELETYPE] = liftIO . sendRawToServer [tIAC, tWONT, tTELETYPE]
    -- Probably not a good idea to send this..
    -- | cmd == [tIAC, tSB, tTELETYPE, tSEND, tIAC, tSE] = sendRawToServer $
    --     [tIAC, tSB, tTELETYPE, tIS] ++ (BS.unpack . BSC.pack $ "parchment") ++ [tIAC, tSE]
    | cmd == [tIAC, tDONT, tNAWS] = liftIO . sendRawToServer [tIAC, tWONT, tNAWS]
    | cmd == [tIAC, tWILL, tGMCP] = liftIO . sendRawToServer [tIAC, tDO, tGMCP]
    | [tIAC, tSB, tGMCP] `isPrefixOf` cmd =
        handleGmcp (BSC.unpack . BS.pack . leave 2 . drop 3 $ cmd)
    | cmd == [tIAC, tNOP] = return
    -- TODO: Support these.
    | cmd == [tIAC, tDO, tNAWS] = liftIO . sendRawToServer [tIAC, tWONT, tNAWS]
    | cmd == [tIAC, tWILL, tMXP] = liftIO . sendRawToServer [tIAC, tDONT, tMXP]
    | cmd == [tIAC, tWILL, tMCCP2] = liftIO . sendRawToServer [tIAC, tDONT, tMCCP2]
    | cmd == [tIAC, tWILL, tMSSP] = liftIO . sendRawToServer [tIAC, tDONT, tMSSP]
    | cmd == [tIAC, tWILL, tMSDP] = liftIO . sendRawToServer [tIAC, tDONT, tMSDP]
    | otherwise = return . logError (show cmd)

handleGmcp :: String -> Sess -> IOMaybe Sess
handleGmcp cmd
   | Just (iden, d) <- parseGmcpCmd cmd = evalHook "gmcp-hook" [SCM.String iden, d]
   | otherwise = return . logError "Bad GMCP cmd encountered"

parseGmcpCmd :: String -> Maybe (String, SCM.LispVal)
parseGmcpCmd cmd
    | length cwords <= 1 = Nothing
    | otherwise = do
          let iden = head cwords
          let rest = unwords . tail $ cwords
          json <- JSON.decode . BSL.pack $ rest
          return (iden, jsonToScheme json)
    where cwords = words cmd

jsonToScheme :: JSON.Value -> SCM.LispVal
jsonToScheme JSON.Null = SCM.List []
jsonToScheme (JSON.Bool b) = SCM.Bool b
jsonToScheme (JSON.String s) = SCM.String (TXT.unpack s)
jsonToScheme (JSON.Number n) = case floatingOrInteger n of
                                   Left r -> SCM.Number . floor $ (r :: Double)
                                   Right i -> SCM.Number $ i
jsonToScheme (JSON.Array a) = SCM.List . map jsonToScheme $ VEC.toList a
jsonToScheme (JSON.Object o) = SCM.HashTable $ fromList . convertVals . HML.toList $ o
    where convertVals = map (\(a,b) -> (SCM.String (TXT.unpack a), jsonToScheme b))

-- Draw the UI.
drawUI :: Sess -> [Widget()]
drawUI sess =
    -- TODO: Make this more efficient with format strings or Data.Text or something.
    [vBox [ drawStatusLine $ "parchment [" ++ (sess ^. (settings . hostname)) ++
                ":" ++ show (sess ^. (settings . port)) ++ "]"
          , padBottom Max . drawBuffer . fromJust $ sess ^? currentBuffer . buffer
          , drawStatusLine ""
          , hBox [ str "> "
                 , showCursor () (Location (sess ^. cursor, 0))
                       (if length input > 0 then str input else str " ")
                 ]

          ]]
    where input = getInput sess

-- A bit hackish.. this is the number of vertical lines in the interface
-- that aren't reserved for the buffer.
nonBufferLines :: Int
nonBufferLines = 3 -- one for the input line, one each for top/bottom status lines

-- lines, buffer -> bounds
bufferBounds :: Int -> RB.RingBuffer a -> (Int, Int)
bufferBounds lines rb = (0, RB.length rb - lines + 1)

drawBuffer :: I.Indexed (RB.RingBuffer FString) -> Widget()
drawBuffer buf =
    Widget Greedy Greedy $ do
        ctx <- getContext
        let num_lines = ctx ^. availHeightL
        let width = ctx ^. availWidthL
        render $ foldr (<=>) (str "") . fmap drawBufferLine . concat .
            fmap (chunksOfKeepBlanks width) . S.reverse . S.take num_lines .
            I.atCurrIndex (flip RB.drop) $ buf
    where fcharToMarkup fc = (TXT.singleton $ _ch fc) @@ (_attr fc)
          drawBufferLine [] = str " " -- handle blank case
          drawBufferLine fs = markup . mconcat . fmap fcharToMarkup $ fs
          chunksOfKeepBlanks _ [] = [[]]
          chunksOfKeepBlanks n l = chunksOf n l

drawStatusLine :: String -> Widget()
drawStatusLine line =
    Widget Greedy Fixed $ do
        ctx <- getContext
        let width = ctx ^. availWidthL
        let spaces = max 0 $ width - length line
        let full_line = line ++ (take spaces $ repeat ' ')
        let formatted = TXT.pack full_line @@
                            ( flip V.withForeColor V.white
                            .  flip V.withBackColor (V.rgbColor 0 95 135) $ V.defAttr)
        render . markup $ formatted
