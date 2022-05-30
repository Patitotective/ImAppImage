import std/[asyncdispatch, httpclient, algorithm, strutils, sequtils, strformat, browsers, logging, options, times, os]

import chroma
import imstyle
import niprefs
import stb_image/read
import nimgl/[opengl, glfw]
import nimgl/imgui, nimgl/imgui/[impl_opengl, impl_glfw]

import src/[prefsmodal, utils, icons, feed]

type
  DownState = enum
    NotDownloaded
    Downloading
    Downloaded

const
  green = "#158A1D".parseHtmlColor()
  resourcesDir = "data"
  configPath = "config.niprefs"
  feedUrl = "https://appimage.github.io/feed.json"
  databaseURL = "https://appimage.github.io/database/"
  categories = [
    {
      "xdg": "Audio",
      "en": "Audio",
      "subtitle": "Audio applications",
      "stocksnap": "4C9TCUEARS", 
      "icon": FA_VolumeUp,
    }.toTable(),
    {
      "xdg": "AudioVideo",
      "en": "Multimedia",
      "stocksnap": "X3SP1WEE4Z", 
      "icon": FA_Television,
    }.toTable(),
    {
      "xdg": "Development",
      "en": "Developer Tools",
      "stocksnap": "9OQTUSUS0M", 
      "icon": FA_Code,
    }.toTable(),
    {
      "xdg": "Education",
      "en": "Education",
      "stocksnap": "FYEZGHNQVR", 
      "icon": FA_Book,
    }.toTable(),
    {
      "xdg": "Game",
      "en": "Games",
      "stocksnap": "ZRAPU1GYCI", 
      "icon": FA_Gamepad,
    }.toTable(),
    {
      "xdg": "Graphics",
      "en": "Graphics and Photography",
      "stocksnap": "ZE94OW561P", 
      "icon": FA_Camera,
    }.toTable(),
    {
      "xdg": "Network",
      "en": "Communication and News",
      "stocksnap": "92E981EC6F", 
      "icon": FA_Signal,
    }.toTable(),
    {
      "xdg": "Office",
      "en": "Productivity",
      "stocksnap": "6RHKEELJ8F", 
      "icon": FA_KeyboardO,
    }.toTable(),
    {
      "xdg": "Science",
      "en": "Science",
      "stocksnap": "OH4YBORCRB", 
      "icon": FA_CodeFork,
    }.toTable(),
    {
      "xdg": "Settings",
      "en": "Settings",
      "stocksnap": "5WFFFULB4G", 
      "icon": FA_Cog,
    }.toTable(),
    {
      "xdg": "System",
      "en": "System",
      "stocksnap": "IKTONP88LJ", 
      "icon": FA_Plug,
    }.toTable(),
    {
      "xdg": "Utility",
      "en": "Utilities",
      "stocksnap": "JY874BSKKC", 
      "icon": FA_Calculator,
    }.toTable(),
    {
      "xdg": "Video",
      "en": "Video",
      "stocksnap": "H0O97B44CT", 
      "icon": FA_VideoCamera,
    }.toTable(),
  ]

var
  logger: FileLogger
  timeout = 0
  # Downloads
  downTable: Table[string, DownState] # Table[path, state]
  downThread: Thread[void] # Downloads thread
  toDown: Channel[tuple[url, path: string]] # To make downThread download something
  fromDown: Channel[tuple[ok: bool, path: string]] # From downThread, telling that it finished a download

proc waitForDownloads() {.async.} =
  while true:
    let maybe = toDown.tryRecv()
    if not maybe.dataAvailable:
      await sleepAsync(100)
    else:
      closureScope:
        let
          (url, path) = maybe.msg
          client = newAsyncHttpClient()
          fut = client.downloadFile(url, path)

        fut.addCallback do ():
          try:
            fut.read()
          except HttpRequestError, OSError: # Invalid URL, no internet
            discard

          fromDown.send((not fut.failed, path))
          client.close()

proc getCacheDir(app: App): string = 
  getCacheDir(app.config["name"].getString())

proc getDownload(app: App, path: string): string = 
  app.getCacheDir() / path

proc cancelDownloads(app: App) = 
  for path, state in downTable:
    if state == Downloading and path.fileExists():
      path.removeFile()
      logger.log(lvlDebug, "Canceling download of ", path)

proc download(app: App, url, path: string, replace: bool = false) = 
  let path = app.getDownload(path)
  if not replace and path.fileExists(): downTable[path] = Downloaded; return
  path.checkFile()
  
  toDown.send((url, path))
  downTable[path] = Downloading

  logger.log(lvlInfo, "Downloading ", url, " to ", path)

proc checkDownload(app: App, path: string): DownState = 
  let path = app.getDownload(path)
  if path.fileExists() and (path notin downTable or path in downTable and downTable[path] != Downloading):
    downTable[path] = Downloaded
  elif path notin downTable:
    downTable[path] = NotDownloaded

  downTable[path]

proc removeDownload(app: App, path: string, cachePath: bool = true) = 
  var path = path
  if cachePath:
    path = app.getDownload(path)

  downTable[path] = NotDownloaded
  if path.fileExists(): path.removeFile()

proc checkDownloads(app: App) = 
  if (let (available, msg) = fromDown.tryRecv(); available):
    if msg.ok and msg.path in downTable:
      if fileExists(msg.path):
        downTable[msg.path] = Downloaded
        logger.log(lvlInfo, "Downloaded ", msg.path)

  # Check for feed.json file
  if app.feed.isNone and app.checkDownload("feed.json") == Downloaded:
    app.feed = readFile(app.getDownload("feed.json")).parseFeed().some
  elif app.checkDownload("feed.json") == NotDownloaded:
    app.download(feedUrl, "feed.json", replace = true)

proc checkImage(app: var App, path: string): tuple[ok: bool, data: ImageData] = 
  if path notin app.imgTable:
    try:
      app.imgTable[path] = path.readImage()
    except STBIException: # Unable to load the image
      result.ok = false
    if app.imgTable[path].pixels[0].addr.isNil: result.ok = false
  else:
    result = (true, app.imgTable[path])

proc drawAboutModal(app: var App) = 
  var center: ImVec2
  getCenterNonUDT(center.addr, igGetMainViewport())
  igSetNextWindowPos(center, Always, igVec2(0.5f, 0.5f))

  if igBeginPopupModal("About " & app.config["name"].getString(), flags = makeFlags(AlwaysAutoResize)):

    # Display icon image
    if (let (ok, data) = app.checkImage(app.config["iconPath"].getPath()); ok):
      igImageFromData(data, igVec2(64, 64)) # Or igVec2(data.width.float32, data.height.float32)

    igSameLine()
    
    igPushTextWrapPos(250)
    igTextWrapped(app.config["comment"].getString())
    igPopTextWrapPos()

    igSpacing()

    igTextWrapped("Credits: " & app.config["authors"].getSeq().mapIt(it.getString()).join(", "))

    if igButton("Ok"):
      igCloseCurrentPopup()

    igSameLine()

    igText(app.config["version"].getString())

    igEndPopup()

proc drawExploreApp(app: var App) = 
  let
    style = igGetStyle()
    item = app.feed.get.items[app.currentApp]
    # FIXME Ignore scalable icons for now
    icon = if item.icons.isSome and item.icons.get[0].splitFile().ext != ".svg": item.icons.get[0] else: ""
    shot = if item.screenshots.isSome: item.screenshots.get[0] else: ""
    iconSize = 72f

  if igButton("Back " & FA_ArrowCircleLeft):
    app.currentApp = -1

  igSpacing()

  if igBeginChild("App Info"):
  
    igSpacing()
    igSpacing()
  
    igBeginGroup()

    if icon.len > 0 and app.checkDownload(icon) == NotDownloaded:
      app.download(databaseURL & icon, icon)

    if icon.len > 0 and app.checkDownload(icon) == Downloaded and (let (ok, data) = app.checkImage(app.getDownload(icon)); ok):
      igImageFromData(data, igVec2(iconSize, iconSize))
    else:
      igImage(nil, igVec2(iconSize, iconSize))

    igSpacing()

    igPushStyleColor(ImGuiCol.Button, green.igVec4())
    igPushStyleColor(ButtonHovered, green.lighten(0.1).igVec4())
    igPushStyleColor(ButtonActive, green.darken(0.1).igVec4())

    if item.links.isNone:
      igPushItemFlag(ImGuiItemFlags.Disabled, true)
      igPushStyleVar(ImGuiStyleVar.Alpha, igGetStyle().alpha * 0.6)

    if igButton("Download"):
      item.links.get[1].url.openDefaultBrowser()

    igPopStyleColor(3)
    if item.links.isNone:
      igPopStyleVar()
      igPopItemFlag()

    if item.links.isSome:
      if igButton("GitHub " & FA_ExternalLink):
        openDefaultBrowser("https://github.com/" & item.links.get[0].url)

    if item.categories.isSome:
      igText("Categories: " & item.categories.get.join(", "))

    if item.authors.isSome:
      igText("Authors: ")
      igSameLine(0f, style.itemInnerSpacing.x)
      for e, author in item.authors.get:
        if e in 1..<item.authors.get.len:
          igSameLine(0f, 0.1)
          igText(", ")
          igSameLine(0f, style.itemInnerSpacing.x)
        
        igTextURL(author.name, author.url, sameLineAfter = false)

    if item.license.isSome:
      igText("License: " & item.license.get)

    igEndGroup()

    igSameLine()

    igBeginGroup()

    app.strongFont.igPushFont()
    igText(item.name)
    igPopFont()

    if item.description.isSome:
      igTextWrapped(item.description.get.removeInside('<', '>'))
    else:
      igText("No description provided.")

    igSpacing()

    if shot.len > 0: 
      if app.checkDownload(shot) == NotDownloaded:
        app.download(databaseURL & shot, shot)
      elif app.checkDownload(shot) == Downloaded:
        if (let (ok, data) = app.checkImage(app.getDownload(shot)); ok):
          # igImageFromData(data)
          # Load empty image for now so it doesn't crash
          igImage(nil, igVec2(data.width.float32, data.height.float32))

    igEndGroup()
    igEndChild()

proc drawAppsChild(app: var App, items: seq[FeedEntry], category: string = "") = 
  let
    # style = igGetStyle()
    # windowVisibleX2 = igGetWindowPos().x + igGetWindowContentRegionMax().x
    items = items.sorted(proc(x, y: FeedEntry): int = system.cmp(x.name, y.name), if app.prefs["sort"] == 0: Ascending else: Descending)

  if category.len > 0:
    igInputTextWithHint("##search", &"Search AppImages in {category} {FA_Search}", app.searchBuf, 100)
  else:
    igInputTextWithHint("##search", &"Search AppImages {FA_Search}", app.searchBuf, 100)

  igSameLine()

  if not app.prefs["viewMode"].getBool():
    igPushItemFlag(ImGuiItemFlags.Disabled, true)
    igPushStyleVar(ImGuiStyleVar.Alpha, igGetStyle().alpha * 0.6)

  if igButton(FA_List):
    app.prefs["viewMode"] = false
  elif not app.prefs["viewMode"].getBool():
    igPopItemFlag()
    igPopStyleVar()

  igSameLine()

  if app.prefs["viewMode"].getBool():
    igPushItemFlag(ImGuiItemFlags.Disabled, true)
    igPushStyleVar(ImGuiStyleVar.Alpha, igGetStyle().alpha * 0.6)

  if igButton(FA_Th):
    app.prefs["viewMode"] = true
  elif app.prefs["viewMode"].getBool():
    igPopItemFlag()
    igPopStyleVar()

  igSameLine()

  if igButton(FA_Sort):
    igOpenPopup("sortPopup")

  if igBeginPopup("sortPopup"):
    if igRadioButton(FA_SortAlphaAsc, app.sort.addr, 0): app.prefs["sort"] = 0
    if igRadioButton(FA_SortAlphaDesc, app.sort.addr, 1): app.prefs["sort"] = 1
    igEndPopup()

  igSpacing()

  if app.prefs["viewMode"].getBool(): # TODO Grid
    # let iconSize = 64f
    igText(":[")
  else: # List
    let iconSize = 48f
    var visible = -1 # TODO add pages
    if igBeginChild("Apps"):
      for e, item in items:
        if visible >= app.viewLimit: app.viewLimit += app.viewChange
        if visible > 0 and visible < app.viewLimit-app.viewChange: app.viewLimit -= app.viewChange
        if e > app.viewLimit: continue

        if igSelectable(&"##app{e}", size = igVec2(0, iconSize)):
          app.currentApp = app.feed.get.items.find(item)

        if not igIsItemVisible():
          continue

        if e > visible: visible = e

        var desc = "No description"

        if item.description.isSome:
          desc = item.description.get.removeInside('<', '>')
          if "\n" in desc:
            desc = desc.split("\n")[0] & "..."

          let max = (0.13 * igGetContentRegionAvail().x).int 
          if desc.len > max:
            desc = desc[0..<max] & "..."

        let
          # FIXME Ignore scalable icons for now
          icon = if item.icons.isSome and item.icons.get[0].splitFile().ext != ".svg": item.icons.get[0] else: ""

        if icon.len > 0 and igIsItemVisible() and app.checkDownload(icon) == NotDownloaded:
          app.download(databaseURL & icon, icon)

        igSameLine()

        if icon.len > 0 and app.checkDownload(icon) == Downloaded and (let (ok, data) = app.checkImage(app.getDownload(icon)); ok):
          igImageFromData(data, igVec2(iconSize, iconSize))
        else:
          igImage(nil, igVec2(iconSize, iconSize))

        igSameLine()

        igBeginGroup()

        app.strongFont.igPushFont()
        igText(item.name)
        igPopFont()

        igText(desc)

        igEndGroup()

      igEndChild()

proc drawExploreCategory(app: var App) = 
  let category = categories[app.currentCategory]

  if igButton("Back " & FA_ArrowCircleLeft):
    app.currentCategory = -1
    app.searchBuf = newString(100)

  igSameLine()

  # Filter by categories
  var items = app.feed.get.items.filterIt(it.categories.isSome and category["xdg"] in it.categories.get)
  # Filter by search
  if (let search = app.searchBuf.split("\0")[0]; search.len > 0):
    items = items.filterIt(search.toLowerAscii().strip() in it.name.toLowerAscii().strip())

  app.drawAppsChild(items, category["en"])

proc drawExploreMain(app: var App) = 
  let
    style = igGetStyle()
    windowVisibleX2 = igGetWindowPos().x + igGetWindowContentRegionMax().x

  for e, category in categories:
    igPushStyleColor(ImGuiCol.Button, igHSV(e / categories.len, 0.6f, 0.6f).value)
    igPushStyleColor(ButtonHovered, igHSV(e / categories.len, 0.8f, 0.8f).value)
    igPushStyleColor(ButtonActive, igHSV(e / categories.len, 1f, 1f).value)

    if igButton(category["en"] & " " & category["icon"]):
      app.currentCategory = e
      app.searchBuf = newString(100)

    igPopStyleColor(3)

    let
      lastButtonX2 = igGetItemRectMax().x
      nextButtonX2 = lastButtonX2 + style.itemSpacing.x + (if e < categories.high: igCalcTextSize(categories[e+1]["en"]).x else: 0) # Expected position if next button was on same line
    
    if e + 1 < categories.len and nextButtonX2 < windowVisibleX2:
      igSameLine()

  igSpacing()

  var items = app.feed.get.items
  if (let search = app.searchBuf.split("\0")[0]; search.len > 0):
    items = items.filterIt(search.toLowerAscii().strip() in it.name.toLowerAscii().strip())

  app.drawAppsChild(items)

proc drawExploreTab(app: var App) = 
  if app.currentApp > -1:
    app.drawExploreApp()
  elif app.currentCategory > -1:
    app.drawExploreCategory()
  else:
    app.drawExploreMain()

  igEndTabItem()

proc drawInstalledTab(app: var App) = 
  igText("WIP")
  igEndTabItem()

proc drawTabs(app: var App) = 
  if igBeginTabBar("Tabs"):
    if igBeginTabItem("Explore " & FA_Globe):
      app.drawExploreTab()

    if igBeginTabItem("Installed " & FA_Download):
      app.drawInstalledTab()

    if igBeginTabItem("Updates " & FA_CloudDownload):
      igText("Unavailable")
      igEndTabItem()

    igEndTabBar()

proc drawMainMenuBar(app: var App) =
  var openAbout, openPrefs = false

  if igBeginMainMenuBar():
    if igBeginMenu("File"):
      igMenuItem("Preferences " & FA_Cog, "Ctrl+P", openPrefs.addr)
      if igMenuItem("Quit " & FA_Times, "Ctrl+Q"):
        app.win.setWindowShouldClose(true)
      igEndMenu()

    if igBeginMenu("Edit"):
      if igMenuItem("Clear Cache"):
        logger.log(lvlInfo, "Clearing cache ", app.getCacheDir())
        for kind, path in app.getCacheDir().walkDir:
          if kind == pcDir: path.removeDir()
          if kind == pcFile and path.splitFile.ext != ".log": path.removeFile()

        downTable = {app.getDownload("feed.json"): NotDownloaded}.toTable()

      if igMenuItem("Refresh " & FA_Refresh, "Ctrl+R"):
        app.removeDownload("feed.json")

      igEndMenu()

    if igBeginMenu("About"):
      if igMenuItem("Website " & FA_Heart):
        app.config["website"].getString().openDefaultBrowser()

      igMenuItem("About " & app.config["name"].getString(), shortcut = nil, p_selected = openAbout.addr)

      igEndMenu() 

    igEndMainMenuBar()

  # See https://github.com/ocornut/imgui/issues/331#issuecomment-751372071
  if openPrefs:
    igOpenPopup("Preferences")
  if openAbout:
    igOpenPopup("About " & app.config["name"].getString())

  # These modals will only get drawn when igOpenPopup(name) are called, respectly
  app.drawAboutModal()
  app.drawPrefsModal()

proc drawMain(app: var App) = # Draw the main window
  let viewport = igGetMainViewport()
  app.drawMainMenuBar()
  
  igSetNextWindowPos(viewport.workPos)
  igSetNextWindowSize(igVec2(viewport.size.x, viewport.workSize.y - igGetFrameHeight()))

  if igBegin(app.config["name"].getString(), flags = makeFlags(ImGuiWindowFlags.NoResize, NoDecoration, NoMove)):
    if app.checkDownload("feed.json") != Downloaded:
      igCenterCursor(ImVec2(x: 15 * 2, y: (15 + igGetStyle().framePadding.y) * 2))
      igSpinner("##spinner", 15, 6, igGetColorU32(ButtonHovered))
    elif app.checkDownload("feed.json") == Downloaded: # Finished
      app.drawTabs()

    igEnd()

  # Status Bar
  igSetNextWindowPos(igVec2(viewport.workPos.x, viewport.workPos.y + viewport.workSize.y - igGetFrameHeight()))
  igSetNextWindowSize(igVec2(viewport.workSize.x, igGetFrameHeight()))

  if igBegin("Status Bar", flags = makeFlags(ImGuiWindowFlags.NoInputs, NoDecoration, NoMove, NoScrollWithMouse, NoBringToFrontOnFocus, NoBackground, MenuBar)):
    if igBeginMenuBar():
      igText(app.statusMsg)
      igEndMenuBar()
    igEnd()

proc display(app: var App) = # Called in the main loop
  glfwPollEvents()

  igOpenGL3NewFrame()
  igGlfwNewFrame()
  igNewFrame()

  app.drawMain()

  igRender()

  let bgColor = igGetStyle().colors[WindowBg.ord]
  glClearColor(bgColor.x, bgColor.y, bgColor.z, bgColor.w)
  glClear(GL_COLOR_BUFFER_BIT)

  igOpenGL3RenderDrawData(igGetDrawData())  

proc initWindow(app: var App) = 
  glfwWindowHint(GLFWContextVersionMajor, 3)
  glfwWindowHint(GLFWContextVersionMinor, 3)
  glfwWindowHint(GLFWOpenglForwardCompat, GLFW_TRUE)
  glfwWindowHint(GLFWOpenglProfile, GLFW_OPENGL_CORE_PROFILE)
  glfwWindowHint(GLFWResizable, GLFW_TRUE)
  
  app.win = glfwCreateWindow(
    app.prefs["win/width"].getInt().int32, 
    app.prefs["win/height"].getInt().int32, 
    app.config["name"].getString(), 
    icon = false # Do not use default icon
  )

  if app.win == nil:
    quit(-1)

  # Set the window icon
  var icon = initGLFWImage(app.config["iconPath"].getPath().readImage())
  app.win.setWindowIcon(1, icon.addr)

  app.win.setWindowSizeLimits(app.config["minSize"][0].getInt().int32, app.config["minSize"][1].getInt().int32, GLFW_DONT_CARE, GLFW_DONT_CARE) # minWidth, minHeight, maxWidth, maxHeight
  app.win.setWindowPos(app.prefs["win/x"].getInt().int32, app.prefs["win/y"].getInt().int32)

  app.win.makeContextCurrent()

proc initPrefs(app: var App) = 
  app.prefs = toPrefs({
    sort: 0, # 0 meaning alpha-asc, 1 meaning alpha-desc
    viewMode: false, # false meaning list, true meaning grid
    win: {
      x: 0,
      y: 0,
      width: 500,
      height: 500
    }
  }).initPrefs(app.getCacheDir() / app.config["prefsPath"].getString())

proc initconfig(app: var App, settings: PrefsNode) = 
  # Add the preferences with the values defined in config["settings"]
  for name, data in settings: 
    let settingType = parseEnum[SettingTypes](data["type"])
    if settingType == Section:
      app.initConfig(data["content"])  
    elif name notin app.prefs:
      app.prefs[name] = data["default"]

proc initApp(config: PObjectType): App = 
  result = App(config: config, feed: Feed.none, currentCategory: -1, currentApp: -1, searchBuf: newString(100), viewChange: 25)
  result.viewLimit = result.viewChange
  result.initPrefs()
  result.initConfig(result.config["settings"])

  result.sort = result.prefs["sort"].getInt().int32

  # Logging
  logger = newFileLogger(
    (result.getCacheDir() / result.config["name"].getString()).changeFileExt("log"), 
    fmtStr = "[$time] - $levelname: ", 
    mode = fmWrite
  )

  logger.log(lvlDebug, "Starting ", getAppFilename(), " ", getDateStr())

  # Downloads
  toDown.open()
  fromDown.open()
  downThread.createThread(proc() = waitFor waitForDownloads())

proc terminate(app: var App) = 
  toDown.close()
  fromDown.close()

  app.cancelDownloads()

  var x, y, width, height: int32
  app.win.getWindowPos(x.addr, y.addr)
  app.win.getWindowSize(width.addr, height.addr)
  
  app.prefs["win/x"] = x
  app.prefs["win/y"] = y
  app.prefs["win/width"] = width
  app.prefs["win/height"] = height

  app.win.destroyWindow()
  logger.log(lvlDebug, "Terminating ", getAppFilename(), " ", getDateStr())

proc main(app: var App) =
  doAssert glfwInit()
  app.initWindow()
  doAssert glInit()

  let context = igCreateContext()
  let io = igGetIO()
  io.iniFilename = nil # Disable ini file

  # Load fonts
  app.font = io.fonts.addFontFromFileTTF(app.config["fontPath"].getPath(), app.config["fontSize"].getFloat())

  # Add ForkAwesome icon font
  var config = utils.newImFontConfig(mergeMode = true)
  var ranges = [FA_Min.uint16,  FA_Max.uint16]
  io.fonts.addFontFromFileTTF(app.config["iconFontPath"].getPath(), app.config["fontSize"].getFloat(), config.addr, ranges[0].addr)

  app.strongFont = io.fonts.addFontFromFileTTF(app.config["strongFontPath"].getPath(), app.config["fontSize"].getFloat() + 3)

  # Merge icon font with strong font again
  io.fonts.addFontFromFileTTF(app.config["iconFontPath"].getPath(), app.config["fontSize"].getFloat(), config.addr, ranges[0].addr)

  doAssert igGlfwInitForOpenGL(app.win, true)
  doAssert igOpenGL3Init()

  # Load application style
  setIgStyle(app.config["stylePath"].getPath())

  while not app.win.windowShouldClose:
    app.checkDownloads()
    app.display()
    app.win.swapBuffers()
    inc timeout
    if timeout > 1000:
      break

  igOpenGL3Shutdown()
  igGlfwShutdown()
  context.igDestroyContext()

  app.terminate()

  glfwTerminate()

when isMainModule:
  var app = initApp(configPath.getPath().readPrefs())
  try:
    app.main()
  except:
    logger.log(lvlFatal, getCurrentExceptionMsg())
    raise
