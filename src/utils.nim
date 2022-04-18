import std/[typetraits, strutils, strformat, enumutils, macros, math, json, os]

import chroma
import niprefs
import stb_image/read as stbi
import nimgl/[imgui, glfw, opengl]

export enumutils, niprefs

type
  App* = ref object
    win*: GLFWWindow
    font*: ptr ImFont
    strongFont*: ptr ImFont
    prefs*: Prefs
    config*: PObjectType # Prefs table
    cache*: PObjectType # Settings cache

    data*: JsonNode # Data fetched from AppImageHub
    statusMsg*: string
    dataThread*: Thread[void]

    currentCategory*: int
    currentApp*: int

  SettingTypes* = enum
    Input # Input text
    Check # Checkbox
    Slider # Int slider
    FSlider # Float slider
    Spin # Int spin
    FSpin # Float spin
    Combo
    Radio # Radio button
    Color3 # Color edit RGB
    Color4 # Color edit RGBA
    Section

  ImageData* = tuple[image: seq[byte], width, height: int]

# To be able to print large holey enums
macro enumFullRange*(a: typed): untyped =
  newNimNode(nnkBracket).add(a.getType[1][1..^1])

iterator items*(T: typedesc[HoleyEnum]): T =
  for x in T.enumFullRange:
    yield x

proc getEnumValues*[T: enum](): seq[string] = 
  for i in T:
    result.add $i

proc parseEnum*[T: enum](node: PrefsNode): T = 
  case node.kind:
  of PInt:
    result = T(node.getInt())
  of PString:
    try:
      result = parseEnum[T](node.getString().capitalizeAscii())
    except:
      raise newException(ValueError, &"Invalid enum value {node.getString()} for {$T}. Valid values are {$getEnumValues[T]()}")
  else:
    raise newException(ValueError, &"Invalid kind {node.kind} for an enum. Valid kinds are PInt or PString")

proc makeFlags*[T: enum](flags: varargs[T]): T =
  ## Mix multiple flags of a specific enum
  var res = 0
  for x in flags:
    res = res or int(x)

  result = T res

proc getFlags*[T: enum](node: PrefsNode): T = 
  ## Similar to parseEnum but this one mixes multiple enum values if node.kind == PSeq
  case node.kind:
  of PString, PInt:
    result = parseEnum[T](node)
  of PSeq:
    var flags: seq[T]
    for i in node.getSeq():
      flags.add parseEnum[T](i)

    result = makeFlags(flags)
  else:
    raise newException(ValueError, "Invalid kind {node.kind} for {$T} enum. Valid kinds are PInt, PString or PSeq") 

proc parseColor3*(node: PrefsNode): array[3, float32] = 
  case node.kind
  of PString:
    let color = node.getString().parseHtmlColor()
    result[0] = color.r
    result[1] = color.g
    result[2] = color.b 
  of PSeq:
    result[0] = node[0].getFloat()
    result[1] = node[1].getFloat()
    result[2] = node[2].getFloat()
  else:
    raise newException(ValueError, &"Invalid color RGB {node}")

proc parseColor4*(node: PrefsNode): array[4, float32] = 
  case node.kind
  of PString:
    let color = node.getString().replace("#").parseHexAlpha()
    result[0] = color.r
    result[1] = color.g
    result[2] = color.b 
    result[3] = color.a
  of PSeq:
    result[0] = node[0].getFloat()
    result[1] = node[1].getFloat()
    result[2] = node[2].getFloat()
    result[3] = node[3].getFloat()
  else:
    raise newException(ValueError, &"Invalid color RGBA {node}")

proc igVec2*(x, y: float32): ImVec2 = ImVec2(x: x, y: y)

proc igVec4*(x, y, z, w: float32): ImVec4 = ImVec4(x: x, y: y, z: z, w: w)

proc igVec4*(color: Color): ImVec4 = ImVec4(x: color.r, y: color.g, z: color.b, w: color.a)

proc initGLFWImage*(data: ImageData): GLFWImage = 
  result = GLFWImage(pixels: cast[ptr cuchar](data.image[0].unsafeAddr), width: int32 data.width, height: int32 data.height)

proc readImage*(path: string): ImageData = 
  var channels: int
  result.image = stbi.load(path, result.width, result.height, channels, stbi.Default)

proc loadTextureFromData*(data: var ImageData, outTexture: var GLuint) =
    # Create a OpenGL texture identifier
    glGenTextures(1, outTexture.addr)
    glBindTexture(GL_TEXTURE_2D, outTexture)

    # Setup filtering parameters for display
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint) # This is required on WebGL for non power-of-two textures
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint) # Same

    # Upload pixels into texture
    # if defined(GL_UNPACK_ROW_LENGTH) && !defined(__EMSCRIPTEN__)
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0)

    glTexImage2D(GL_TEXTURE_2D, GLint 0, GL_RGBA.GLint, GLsizei data.width, GLsizei data.height, GLint 0, GL_RGBA, GL_UNSIGNED_BYTE, data.image[0].addr)

proc igHelpMarker*(text: string) = 
  igTextDisabled("(?)")
  if igIsItemHovered():
    igBeginTooltip()
    igPushTextWrapPos(igGetFontSize() * 35.0)
    igTextUnformatted(text)
    igPopTextWrapPos()
    igEndTooltip()

proc newImFontConfig*(mergeMode = false): ImFontConfig =
  result.fontDataOwnedByAtlas = true
  result.fontNo = 0
  result.oversampleH = 3
  result.oversampleV = 1
  result.pixelSnapH = true
  result.glyphMaxAdvanceX = float.high
  result.rasterizerMultiply = 1.0
  result.mergeMode = mergeMode

proc getPath*(path: string): string = 
  # When running on an AppImage get the path from the AppImage resources
  when defined(appImage):
    result = getEnv"APPDIR" / resourcesDir / path.extractFilename()
  else:
    result = getAppDir() / path

proc getPath*(path: PrefsNode): string = 
  path.getString().getPath()

proc igSpinner*(label: string, radius: float, thickness: float32, color: uint32) = 
  let window = igGetCurrentWindow()
  if window.skipItems:
    return
  
  let
    context = igGetCurrentContext()
    style = context.style
    id = igGetID(label)
  
    pos = window.dc.cursorPos
    size = ImVec2(x: radius * 2, y: (radius + style.framePadding.y) * 2)

    bb = ImRect(min: pos, max: ImVec2(x: pos.x + size.x, y: pos.y + size.y));
  igItemSize(bb, style.framePadding.y)

  if not igItemAdd(bb, id):
      return
  
  window.drawList.pathClear()
  
  let
    numSegments = 30
    start = abs(sin(context.time * 1.8f) * (numSegments - 5).float)
  
  let
    aMin = PI * 2f * start / numSegments.float
    aMax = PI * 2f * ((numSegments - 3) / numSegments).float

    centre = ImVec2(x: pos.x + radius, y: pos.y + radius + style.framePadding.y)

  for i in 0..<numSegments:
    let a = aMin + i / numSegments * (aMax - aMin)
    window.drawList.pathLineTo(ImVec2(x: centre.x + cos(a + context.time * 8) * radius, y: centre.y + sin(a + context.time * 8) * radius))

  window.drawList.pathStroke(color, thickness = thickness)

proc igHSV*(h, s, v: float32, a: float32 = 1f): ImColor = 
  result.addr.hSVNonUDT(h, s, v, a)

proc igCalcTextSize*(text: cstring, text_end: cstring = nil, hide_text_after_double_hash: bool = false, wrap_width: float32 = -1.0'f32): ImVec2 = 
  igCalcTextSizeNonUDT(result.addr, text, text_end, hide_text_after_double_hash, wrap_width)

proc igGetContentRegionAvail*(): ImVec2 = 
  igGetContentRegionAvailNonUDT(result.addr)

proc igGetWindowContentRegionMax*(): ImVec2 = 
  igGetWindowContentRegionMaxNonUDT(result.addr)

proc igGetItemRectMin*(): ImVec2 = 
  igGetItemRectMinNonUDT(result.addr)

proc igGetItemRectMax*(): ImVec2 = 
  igGetItemRectMaxNonUDT(result.addr)

proc igGetWindowPos*(): ImVec2 = 
  igGetWindowPosNonUDT(result.addr)

proc igCenterCursorX*(width: float32, align: float = 0.5f) = 
  var avail: ImVec2

  igGetContentRegionAvailNonUDT(avail.addr)
  
  let off = (avail.x - width) * align
  
  if off > 0:
    igSetCursorPosX(igGetCursorPosX() + off)

proc igCenterCursorY*(height: float32, align: float = 0.5f) = 
  var avail: ImVec2

  igGetContentRegionAvailNonUDT(avail.addr)
  
  let off = (avail.y - height) * align
  
  if off > 0:
    igSetCursorPosY(igGetCursorPosY() + off)

proc igCenterCursor*(size: ImVec2, alignX: float = 0.5f, alignY: float = 0.5f) = 
  igCenterCursorX(size.x, alignX)
  igCenterCursorY(size.y, alignY)

proc `+`*(vec1, vec2: ImVec2): ImVec2 = 
  igVec2(vec1.x + vec2.x, vec1.y + vec2.y)

proc `+`*(vec: ImVec2, val: float32): ImVec2 = 
  igVec2(vec.x + val, vec.y + val)

proc `-`*(vec1, vec2: ImVec2): ImVec2 = 
  igVec2(vec1.x - vec2.x, vec1.y - vec2.y)

proc `-`*(vec: ImVec2, val: float32): ImVec2 = 
  igVec2(vec.x - val, vec.y - val)

proc removeInside*(s: string, open, close: char): string = 
  var inside = false
  for i in s:
    if i == open: inside = true
    if not inside: result.add i
    if i == close: inside = false

proc igGetCursorPos*(): ImVec2 = 
  igGetCursorPosNonUDT(result.addr)
