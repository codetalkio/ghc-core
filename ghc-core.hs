{-# LANGUAGE PatternGuards #-}
--------------------------------------------------------------------
-- |
-- Module    : ghc-core
-- Copyright : (c) Galois, Inc. 2008
-- License   : BSD3
--
-- Maintainer: Don Stewart <dons@galois.com>
-- Stability : provisional
-- Portability: Needs a few libraries from hackage.
--
--------------------------------------------------------------------
--
-- Inspect the optimised core and assembly produce by GHC.
--
-- Examples:
--
-- > ghc-core zipwith
--
-- > ghc-core -fvia-C zipwith 
--

------------------------------------------------------------------------

import Control.Concurrent
import Control.Exception
import Control.Monad
import Data.List
import Data.Maybe
import System.Console.GetOpt
import System.Directory
import System.Environment
import System.Exit
import System.FilePath
import System.IO
import System.Process hiding (readProcess)
import Text.Printf
import qualified Control.Exception as C

import Text.Regex.PCRE.Light.Char8

-- BSD-licensed Haskell syntax highlighting, based on Programmatica
import Language.Haskell.Colorize

{-
import Language.Haskell.HsColour
import Language.Haskell.HsColour.Colourise
-- 'Literate' is hscolour-1.11 only. 'Bool' was used in hscolour-1.10
import Language.Haskell.HsColour.Options (Literate(..))
-}

------------------------------------------------------------------------
--
-- Command line parsing
--

data Options = Options
  { optHelp   :: Bool
--  , optFormat :: Output
  , optGhcExe :: String
  , optAsm    :: Bool
  } deriving (Eq, Show)

defaultOptions :: Options
defaultOptions = Options
  { optHelp    = False
--  , optFormat  = TTY
  , optGhcExe  = "ghc"
  , optAsm     = True
  }

-- formats :: [(String, Output)]
-- formats = [("css", CSS), ("html", HTML), ("tty", TTY)]

options :: [OptDescr (Options -> Options)]
options =
    [ --  Option ['f'] ["format"]
      --      (ReqArg (\x opts -> opts { optFormat = fromString x }) "FORMAT")
      --      ("Output format " ++ formats' ++ ".")
         Option ['h'] ["help"]
            (NoArg (\opts -> opts { optHelp = True }))
            "Print this help message."
        ,Option [] ["with-ghc"]
            (ReqArg (\x opts -> opts { optGhcExe = x }) "PROGRAM")
            "Ghc executable to use."
        ,Option [] ["no-asm"]
            (NoArg (\opts -> opts { optAsm = False }))
            "Don't output generated assembly code."
    ]
    where
{-      fromString  f = fromMaybe (formatError f) (lookup f formats)
        formatError f = error $
                            "invalid format `" ++ f ++ "'"
                            ++ ", must be one of " ++ formats' ++ "."
        formats' = "(" ++ concat (intersperse ", " (map fst formats)) ++ ")"
-}

parseOptions :: [String] -> IO (Options, [String])
parseOptions argv = 
    case getOpt RequireOrder options argv of
        (o, n, []) -> let o' = foldl (flip ($)) defaultOptions o in
                        if optHelp o'
                            then do hPutStr stderr (usageInfo header options)
                                    exitWith ExitSuccess
                            else return (o', n)
        (_, _, es) -> ioError (userError (concat es ++ usageInfo header options))
    where header = "Usage: ghc-core [OPTION...] [--] [GHC_OPTION...] [files...]"

isExtCoreFile :: FilePath -> Bool
isExtCoreFile = (== ".hcr") . takeExtension
------------------------------------------------------------------------

main :: IO ()
main = do
    -- Parse command line
    (opts, args) <- getArgs >>= parseOptions

    -- Read colors from .hscolour
--    colourPrefs <- readColourPrefs

    mv <- getEnvMaybe "PAGER"
    let less = case mv of Just s -> case s of "less" -> "less -f" ; _ -> s
                          _      -> "less -f"
 
    (strs, tmps) <- case args of
                      [fp] | isExtCoreFile fp -> do
                                contents <- readFile fp
                                return (contents, Nothing)
                      _ -> do
                        strs' <- polish `fmap` compileWithCore (optGhcExe opts)
                                 args (optAsm opts)
                    -- TODO this is a bit lazy on my part...
                        x <- readProcess "sh" ["-c","ls /tmp/ghc*/*.s | head -1"] []
                        case x of
                          Left _ -> return (strs', Nothing)
                          Right s -> if "-fvia-C" `elem` args
                                       then do asm <- readFile (init s)
                                               return ((strs' ++ asm), Just $ takeDirectory s)
                                       else return (strs', Just $ takeDirectory s)

{-
    -- If we replace the 'NoLit' constructor with 'False' (and
    -- remove the include for the Literate type), then this will
    -- work with older hscolour-1.10.* versions.
    let nice = hscolour
                (optFormat opts)
                colourPrefs False True NoLit [] strs
-}
    let nice = render ansiLight strs []

    bracket
        (openTempFile "/tmp" "ghc-core-XXXX.hcr")
        (\(f,h) -> do hClose h
                      removeFile f
                      case tmps of
                        Just g -> system ("rm -rf " ++ g) >> return ()
                        _      -> return ()
        )
        (\(f,h) -> do
            hPutStrLn h nice >> hFlush h
            e <- system $ less ++ " -r " ++ f
            exitWith e)

--  
-- Clean up the output with some regular expressions.  
--  
polish :: String -> String
polish = unlines . dups . map polish' . lines
    where
        polish' [] = []
        polish' s
            | Just [_,a,b] <- match name  s [] =  polish' (a ++ b)
            | Just [_,a,b] <- match local s [] =  polish' (a ++ b)
            | Just _ <- match core  s [] =  "------------------------------- Core -----------------------------------"
            | Just _ <- match asm   s [] =  "------------------------------- Assembly -------------------------------"

            | Just _       <- match junk  s [] =  []
            | Just _       <- match junk2 s [] =  []
            | Just _       <- match junk3 s [] =  []
            | Just _       <- match junk4 s [] =  []
            | Just _       <- match junk5 s [] =  []
            | Just _       <- match junk6 s [] =  []
            | Just _       <- match junk7 s [] =  []

            | otherwise = s

        -- simplify some qualified names
        name  = compile
                 "^(.*)GHC\\.[^\\.]*\\.(.*)$"
                 [ungreedy]

        local = compile
                 "^(.*)Main\\.(.*)$"
                 [ungreedy]

        -- remove boring things
        core  = compile "Tidy Core" [ungreedy]
        asm   = compile "Asm code" [ungreedy]

        junk  = compile "^.GlobalId" []
        junk2 = compile "^.Arity .*" []
        junk3 = compile "^Rec {|^end Rec" []
        junk4 = compile "DmdType" []
        junk5 = compile "NoCafRefs" []
        junk6 = compile "^\\[\\]$" []
        junk7 = compile "==========" []

        -- remove duplicate blank lines
        dups []         = []
        dups ([]:[]:xs) = dups ([]:xs)
        dups (x:xs) = x : dups xs

------------------------------------------------------------------------

compileWithCore :: String -> [String] -> Bool -> IO String
compileWithCore ghc opts asm = do
    let args = words $ "-O2 -keep-tmp-files -ddump-simpl -ddump-simpl-stats -no-recomp --make" ++ if asm then " -ddump-asm" else ""

    x <- readProcess ghc (args ++ opts) []
    case x of
         Left (err,str,std) -> do
            mapM_ putStrLn (lines str)
            mapM_ putStrLn (lines std)
            printf "GHC failed to compile %s\n" (show err)
            exitWith (ExitFailure 1) -- fatal

         Right str      -> return str

------------------------------------------------------------------------

--
-- Strict process reading 
--
readProcess :: FilePath                              -- ^ command to run
            -> [String]                              -- ^ any arguments
            -> String                                -- ^ standard input
            -> IO (Either (ExitCode,String,String) String)  -- ^ either the stdout, or an exitcode and any output

readProcess cmd args input = C.handle (return . handler) $ do
    (inh,outh,errh,pid) <- runInteractiveProcess cmd args Nothing Nothing

    output  <- hGetContents outh
    outMVar <- newEmptyMVar
    forkIO $ (C.evaluate (length output) >> putMVar outMVar ())

    errput  <- hGetContents errh
    errMVar <- newEmptyMVar
    forkIO $ (C.evaluate (length errput) >> putMVar errMVar ())

    when (not (null input)) $ hPutStr inh input
    takeMVar outMVar
    takeMVar errMVar
    ex     <- C.catch (waitForProcess pid) (\_e -> return ExitSuccess)
    hClose outh
    hClose inh          -- done with stdin
    hClose errh         -- ignore stderr

    return $ case ex of
        ExitSuccess   -> Right output
        ExitFailure _ -> Left (ex, errput, output)

  where
    handler (C.ExitException e) = Left (e,"","")
    handler e                   = Left (ExitFailure 1, show e, "")


-- Safe wrapper for getEnv
getEnvMaybe :: String -> IO (Maybe String)
getEnvMaybe name = handle (const $ return Nothing) (Just `fmap` getEnv name)