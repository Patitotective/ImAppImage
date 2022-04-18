import std/[strutils, sequtils, strformat, browsers, json, os]

import puppy
import chroma
import imstyle
import niprefs
import nimgl/[opengl, glfw]
import nimgl/imgui, nimgl/imgui/[impl_opengl, impl_glfw]

import src/[prefsmodal, utils, icons]

const
  green = "#158A1D".parseHtmlColor()
  resourcesDir = "data"
  configPath = "config.niprefs"
  databaseURL = "https://appimage.github.io/database/"
  categories = [
    {
      "xdg": "Audio",
      "en": "Audio " & FA_VolumeUp,
      "subtitle": "Audio applications",
      "stocksnap": "4C9TCUEARS",
    }.toTable(),
    {
      "xdg": "AudioVideo",
      "en": "Multimedia " & FA_Television,
      "stocksnap": "X3SP1WEE4Z",
    }.toTable(),
    {
      "xdg": "Development",
      "en": "Developer Tools " & FA_Code,
      "stocksnap": "9OQTUSUS0M",
    }.toTable(),
    {
      "xdg": "Education",
      "en": "Education " & FA_Book,
      "stocksnap": "FYEZGHNQVR",
    }.toTable(),
    {
      "xdg": "Game",
      "en": "Games " & FA_Gamepad,
      "stocksnap": "ZRAPU1GYCI",
    }.toTable(),
    {
      "xdg": "Graphics",
      "en": "Graphics and Photography " & FA_Camera,
      "stocksnap": "ZE94OW561P",
    }.toTable(),
    {
      "xdg": "Network",
      "en": "Communication and News " & FA_Signal,
      "stocksnap": "92E981EC6F",
    }.toTable(),
    {
      "xdg": "Office",
      "en": "Productivity " & FA_KeyboardO,
      "stocksnap": "6RHKEELJ8F",
    }.toTable(),
    {
      "xdg": "Science",
      "en": "Science " & FA_CodeFork,
      "stocksnap": "OH4YBORCRB", # FA_ThermometerThreeQuarters
    }.toTable(),
    {
      "xdg": "Settings",
      "en": "Settings " & FA_Cog,
      "stocksnap": "5WFFFULB4G",
    }.toTable(),
    {
      "xdg": "System",
      "en": "System " & FA_Plug,
      "stocksnap": "IKTONP88LJ",
    }.toTable(),
    {
      "xdg": "Utility",
      "en": "Utilities " & FA_Calculator,
      "stocksnap": "JY874BSKKC",
    }.toTable(),
    {
      "xdg": "Video",
      "en": "Video " & FA_VideoCamera,
      "stocksnap": "H0O97B44CT",
    }.toTable(),
  ]

var
  dataChannel: Channel[tuple[msg: string, node: JsonNode]]

proc drawAboutModal(app: var App) = 
  var center: ImVec2
  getCenterNonUDT(center.addr, igGetMainViewport())
  igSetNextWindowPos(center, Always, igVec2(0.5f, 0.5f))

  if igBeginPopupModal("About " & app.config["name"].getString(), flags = makeFlags(AlwaysAutoResize)):

    # Display icon image
    var
      texture: GLuint
      image = app.config["iconPath"].getPath().readImage()

    image.loadTextureFromData(texture)

    igImage(cast[ptr ImTextureID](texture), igVec2(64, 64)) # Or igVec2(image.width.float32, image.height.float32)

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
  let item = app.data["items"][app.currentApp]

  if igButton("Back " & FA_ArrowCircleLeft):
    app.currentApp = -1

  igSpacing()

  if igBeginChild("App Info"):
    
    igBeginGroup()

    igImage(nil, igVec2(64, 64))

    igPushStyleColor(ImGuiCol.Button, green.igVec4())
    igPushStyleColor(ButtonHovered, green.lighten(0.1).igVec4())
    igPushStyleColor(ButtonActive, green.darken(0.1).igVec4())

    if igButton("Download"):
      echo "downloading"

    igPopStyleColor(3)

    igEndGroup()

    igSameLine()

    igBeginGroup()

    app.strongFont.igPushFont()
    igText(item["name"].getStr())
    igPopFont()

    if "description" in item:
      igTextWrapped(item["description"].getStr().removeInside('<', '>'))
    else:
      igText("No description provided.")

    igEndGroup()

    igEndChild()

proc drawExploreCategory(app: var App) = 
  let
    style = igGetStyle()
    drawList = igGetWindowDrawList()
    category = categories[app.currentCategory]

  if igButton("Back " & FA_ArrowCircleLeft):
    app.currentCategory = -1

  igSameLine()

  drawList.channelsSplit(2)
  drawList.channelsSetCurrent(1)

  igCenterCursorX(category["en"].igCalcTextSize().x)
  igText(category["en"])

  drawList.channelsSetCurrent(0)
  
  let (pMin, pMax) = (igGetItemRectMin() - 5, igGetItemRectMax() + 5) 
  drawList.addRectFilled(pMin, pMax, igHSV(app.currentCategory / categories.len, 0.6f, 0.6f).value.igGetColorU32())

  drawList.channelsMerge()

  igSpacing()

  if igBeginChild("Categories List"):
    for e, item in app.data["items"].getElems().filterIt(category["xdg"].newJString() in it["categories"].getElems()):
      igPushId(item["name"].getStr())

      var desc = ""

      if "description" in item:
        desc = item["description"].getStr().removeInside('<', '>')
        if "\n" in desc:
          desc = desc.split("\n")[0] & "..."

      let iconSize = 48f

      if igSelectable(&"##app{e}", size = igVec2(0, iconSize)):
        app.currentApp = app.data["items"].getElems().find(item)

      igSameLine()

      igImage(nil, igVec2(iconSize, iconSize))

      igSameLine()

      igBeginGroup()

      app.strongFont.igPushFont()
      igText(item["name"].getStr())
      igPopFont()

      if desc.len > 0:
        igText(desc)

      igEndGroup()

      igPopId()

    igEndChild()

proc drawExploreMain(app: var App) = 
  let
    style = igGetStyle()
    windowVisibleX2 = igGetWindowPos().x + igGetWindowContentRegionMax().x

  for e, category in categories:
    igPushStyleColor(ImGuiCol.Button, igHSV(e / categories.len, 0.6f, 0.6f).value)
    igPushStyleColor(ButtonHovered, igHSV(e / categories.len, 0.8f, 0.8f).value)
    igPushStyleColor(ButtonActive, igHSV(e / categories.len, 1f, 1f).value)

    if igButton(category["en"]):
      app.currentCategory = e

    igPopStyleColor(3)

    let
      lastButtonX2 = igGetItemRectMax().x
      nextButtonX2 = lastButtonX2 + style.itemSpacing.x + (if e < categories.high: igCalcTextSize(categories[e+1]["en"]).x else: 0) # Expected position if next button was on same line
    
    if e + 1 < categories.len and nextButtonX2 < windowVisibleX2:
      igSameLine()

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

proc fetchdata() = 
  try:
    dataChannel.send(("", fetch("https://appimage.github.io/feed.json").parseJson()))
  except PuppyError:
    dataChannel.send((getCurrentExceptionMsg(), newJNull()))

proc drawMainMenuBar(app: var App) =
  var openAbout, openPrefs = false

  if igBeginMainMenuBar():
    if igBeginMenu("File"):
      igMenuItem("Preferences " & FA_Cog, "Ctrl+P", openPrefs.addr)
      if igMenuItem("Quit " & FA_Times, "Ctrl+Q"):
        app.win.setWindowShouldClose(true)
      igEndMenu()

    if igBeginMenu("Edit"):
      if igMenuItem("Paste " & FA_Clipboard, "Ctrl+V"):
        echo "paste"

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

  # Finished fetching data
  if app.data.kind == JNull and not app.dataThread.running: 
    let data = dataChannel.recv()

    if data.node.kind == JNull: # Failed
      app.statusMsg = "Couldn't fetch data. Trying to fetch data locally"
      if not fileExists("fetch.json"):#app.prefs["data"].getString().len == 0:
        app.statusMsg = "Couldn't fetch data locally. Please try again later."
      else:
        app.data = readFile(getAppDir() / "fetch.json").parseJson()
        app.statusMsg = "Successfully fetched data locally"
    else:
      app.data = data.node
      app.statusMsg = "Successfully fetched data"

  if igBegin(app.config["name"].getString(), flags = makeFlags(ImGuiWindowFlags.NoResize, NoDecoration, NoMove)):
    if app.dataThread.running:
      igCenterCursor(ImVec2(x: 15 * 2, y: (15 + igGetStyle().framePadding.y) * 2))
      igSpinner("##spinner", 15, 6, igGetColorU32(ButtonHovered))
    elif app.data.kind != JNull: # Finished
      app.drawTabs()
    else:
      igText(":[")

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
  when defined(appImage):
    # Put prefsPath right next to the AppImage
    let prefsPath = getEnv"APPIMAGE".parentDir / app.config["prefsPath"].getString()
  else:
    let prefsPath = getAppDir() / app.config["prefsPath"].getString()
  
  app.prefs = toPrefs({
    win: {
      x: 0,
      y: 0,
      width: 500,
      height: 500
    }
  }).initPrefs(prefsPath)

proc initconfig*(app: var App, settings: PrefsNode) = 
  # Add the preferences with the values defined in config["settings"]
  for name, data in settings: 
    let settingType = parseEnum[SettingTypes](data["type"])
    if settingType == Section:
      app.initConfig(data["content"])  
    elif name notin app.prefs:
      app.prefs[name] = data["default"]

proc initApp*(config: PObjectType): App = 
  result = App(config: config, data: newJNull(), currentCategory: -1, currentApp: -1)
  result.initPrefs()
  result.initConfig(result.config["settings"])

  # Fetch data
  result.statusMsg = "Fetching data..."
  result.dataThread.createThread(fetchData)
  dataChannel.open()

proc terminate(app: var App) = 
  if app.data.kind != JNull:
    writeFile(getAppDir() / "fetch.json", $app.data)

  var x, y, width, height: int32

  app.win.getWindowPos(x.addr, y.addr)
  app.win.getWindowSize(width.addr, height.addr)
  
  app.prefs["win/x"] = x
  app.prefs["win/y"] = y
  app.prefs["win/width"] = width
  app.prefs["win/height"] = height

  app.win.destroyWindow()

proc main() =
  var app = initApp(configPath.getPath().readPrefs())

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
    app.display()
    app.win.swapBuffers()

  igOpenGL3Shutdown()
  igGlfwShutdown()
  context.igDestroyContext()

  app.terminate()

  glfwTerminate()

when isMainModule:
  main()
