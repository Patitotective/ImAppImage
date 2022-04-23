import std/[json, options]

type
  Link* = object
    `type`*: string
    url*: string
  Author* = object
    name*, url*: string
  FeedEntry* = object
    name*: string
    description*: Option[string]
    categories*: Option[seq[string]]
    authors*: Option[seq[Author]]
    license*: Option[string]
    links*: Option[seq[Link]]
    icons*, screenshots*: Option[seq[string]]
  Feed* = object
    version*: int
    home_page_url*, feed_url*, description*, icon*, favicon*: string
    expired*: bool
    items*: seq[FeedEntry]

proc parseFeed*(data: string): Feed = 
  data.parseJson.to(Feed)
