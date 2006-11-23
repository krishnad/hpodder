{- hpodder component
Copyright (C) 2006 John Goerzen <jgoerzen@complete.org>

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
-}

{- |
   Module     : DownloadQueue
   Copyright  : Copyright (C) 2006 John Goerzen
   License    : GNU GPL, version 2 or above

   Maintainer : John Goerzen <jgoerzen@complete.org>
   Stability  : provisional
   Portability: portable

Written by John Goerzen, jgoerzen\@complete.org

-}

module DownloadQueue where
import Download
import MissingH.Cmd
import System.Posix.Process
import Config
import MissingH.Logging.Logger
import Text.Printf
import System.Exit
import System.Directory
import System.Posix.Files
import System.Posix.Signals
import MissingH.Checksum.MD5
import MissingH.ProgressTracker
import Network.URI
import Data.List
import Control.Concurrent.MVar
import Control.Concurrent
import Data.Char

d = debugM "downloadqueue"
i = infoM "downloadqueue"

data (Eq a, Ord a, Show a) => DownloadEntry a = 
    DownloadEntry {dlurl :: String,
                   usertok :: a}
    deriving (Eq, Ord, Show)

data (Eq a, Ord a, Show a) => DownloadQueue a =
    DownloadQueue {pendingHosts :: [(String, DownloadEntry a)],
                   -- activeDownloads :: (DownloadEntry, DownloadTok),
                   basePath :: FilePath,
                   allowResume :: Bool,
                   callbackFunc :: (DownloadEntry a -> DLAction -> IO ()),
                   completedDownloads :: [(DownloadEntry a, DownloadTok, Result)]}

data DLAction = DLStarted DownloadTok | DLEnded (DownloadTok, Result)
              deriving (Eq, Show)

groupByHost :: (Eq a, Show a, Ord a) => [DownloadEntry a] -> [(String, DownloadEntry a)]
groupByHost dllist =
    combineGroups .
    groupBy (\(host1, _) (host2, _) -> host1 == host2) . sort .
    map (\(x, y) -> (map toLower x, y)) . -- lowercase the hostnames
    map conv $ dllist
    where conv de = case parseURI (dlurl de) of
                      Nothing -> ("", de)
                      Just x -> (x, de)
          combineGroups :: [[(String, DownloadEntry)]] -> [(String, DownloadEntry)]
          combineGroups [] = []
          combineGroups (x:xs) =
              (fst . head $ x, map snd x) : combineGroups xs

runDownloads :: (Eq a, Ord a, Show a) => 
                  (DownloadEntry a -> DLAction -> IO ()) -> -- Callback when a download starts or stops
                  FilePath ->   --  Base path
                  Bool ->       -- Whether or not to allow resume
                  [DownloadEntry a] -> --  Items to download
                  Int ->        --  Max number of download threads
                  IO [(DownloadEntry a, DownloadTok, Result)] -- The completed DLs
runDownloads callbackfunc basefp resumeOK delist maxthreads =
    do oldsigs <- blocksignals
       dqmvar <- newMVar $ DownloadQueue {pendingHosts = groupByHost delist,
                                          completedDownloads = [],
                                          basePath = basefp,
                                          allowResume = resumeOK,
                                          callbackFunc = callbackfunc}
       semaphore <- newQSem 0 -- Used by threads to signal they're done
       mapM_ (\_ -> forkIO (childthread dqmvar semaphore)) [1..maxthreads]
       mapM_ (\_ -> waitQSem semaphore) [1..maxthreads]
       restoresignals oldsigs
       withMVar dqmvar (\dq -> return (completedDownloads dq))

childthread dqmvar semaphore =
    do workdata <- getworkdata
       if workdata == []
          then signalQSem semaphore        -- We're done!
          else do processChildWorkData workdata
                  childthread dqmvar semaphore -- And look for more hosts
    where getworkdata = modifyMVar dqmvar $ \dq ->
             do case pendingHosts dqmvar of
                  [] -> return (dq, [])
                  (x:xs) -> return (dq {pendingHosts = xs}, snd x)
          processChildWorkData [] = return []
          processChildWorkData (x:xs) = 
              do (basefp, resumeOK, callback) <- withMVar dqmvar 
                             (\dq -> return (basePath dq, allowResume dq,
                                            callbackFunc dq))
                 dltok <- startGetURL (dlurl x) basefp resumeOK
                 callback x (DLStarted dltok)
                 status <- getProcessStatus ((\(p, _, _) -> p) dltok)
                 result <- finishGetURL dltok status

                 -- Add to the completed DLs list.  Also do callback here
                 -- so it's within the lock.  Handy to prevent simultaneous
                 -- DB updates.
                 modifyMVar_ dqmvar $ \dq -> 
                     do callback x (DLEnded (dltok, result))
                        return (dq {completedDownloads = 
                                        (x, dltok, result) :
                                        completedDownloads dq})
                 processChildWorkData xs     -- Do the next one

blocksignals = 
    do let sigset = addSignal sigCHLD emptySignalSet
       oldset <- getSignalMask
       blockSignals sigset
       return oldset

restoresignals = setSignalMask