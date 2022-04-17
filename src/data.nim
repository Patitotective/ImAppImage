import std/[asyncdispatch, httpclient, os]
import zip/zipfiles
import utils

const
  dataZip = "data.zip"
  sourceDataUrl = "https://github.com/AppImage/appimage.github.io/archive/refs/heads/master.zip"
  sourceDataDir = "appimage.github.io-master"

proc downloadData*(onProgress: ProgressChangedProc[Future[void]]) =
  var client = newAsyncHttpClient()
  client.onProgressChanged = onProgress

  waitFor client.downloadFile(sourceDataUrl, dataZip)

proc unzipData*(app: App) = 
  if not fileExists(dataZip):
    raise newException(OSError, "Couldn't find " & dataZip)

  var z: ZipArchive
  if not z.open(dataZip):
    raise newException(OSError, "Couldn't open " & dataZip)

  z.extractAll(getAppDir())
  z.close()

  if dirExists(sourceDataDir):
    moveDir(sourceDataDir, app.config["dataDir"].getPath())

