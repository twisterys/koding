{argv}                  = require 'optimist'
{uri}                   = require('koding-config-manager').load("main.#{argv.c}")
{daisy}                 = require "bongo"
encoder                 = require 'htmlencode'
{createActivityContent} = require '../helpers'

createProfileContent = (models, account, profileBuilder, options, callback)->
  { client, name, page, route } = options
  { JAccount, SocialChannel } = models
  targetId = account.socialApiId
  sessionToken = client.sessionToken

  SocialChannel.fetchProfileFeedCount client, {targetId, sessionToken}, (err, response)->
    return callback err  if err
    itemCount = response?.totalCount
    return callback null, profileBuilder account, ""  unless itemCount

    itemsPerPage = 5
    skip = 0
    if page > 0
      skip = (page - 1) * itemsPerPage
      
    fetchOptions =
      targetId   : targetId
      limit      : itemsPerPage
      skip       : skip
      replyLimit : 25

    SocialChannel.fetchProfileFeed client, fetchOptions, (err, result) ->
      return callback err  if err or not result
      unless result.length
        return callback null, profileBuilder account, ""

      buildContent models, result, options, (err, content) ->
        return callback err  if err or not content

        pagination = getPagination page, itemCount, itemsPerPage, "#{account.profile.nickname}"
        fullPage = profileBuilder account, content, pagination

        callback null, fullPage


createFeed = (models, options, callback)->
  {JAccount, SocialChannel} = models
  { page, channelId, client
    route, contentType, channelName, sessionToken } = options

  return callback "channelId not set"  unless channelId

  itemsPerPage = 20
  skip = 0
  if page > 0
    skip = (page - 1) * itemsPerPage

  options = {
    id          : channelId
    limit       : itemsPerPage
    skip        : skip
    channelName : channelName
    sessionToken
  }

  SocialChannel.fetchActivityCount {channelId, sessionToken}, (err, response)->
    return callback err  if err
    itemCount = response?.totalCount
    return callback null, getEmptyPage channelName  unless itemCount

    options.replyLimit = 25
    SocialChannel.fetchActivities client, options, (err, result) ->
      return callback err  if err

      {messageList} = result
      return callback null, getEmptyPage channelName unless messageList?.length

      options.page = page
      buildContent models, result.messageList, options, (err, pageContent) ->
        return callback err  if err
        schemaorgTagsOpening = getSchemaOpeningTags contentType
        schemaorgTagsClosing = getSchemaClosingTags contentType
        channelTitleContent  = getChannelTitleContent channelName

        content = schemaorgTagsOpening + channelTitleContent +
          pageContent + schemaorgTagsClosing

        pagination = getPagination page, itemCount, itemsPerPage, "Activity/#{route}"
        fullPage = putContentIntoFullPage content, pagination

        callback null, fullPage


getChannelTitleContent = (channelName) ->
  content = "<div class='logged-out channel-title'>##{channelName}</div>"


buildContent = (models, messageList, options, callback) ->
  {SocialChannel} = models
  {client, page} = options

  pageContent = ""
  queue = messageList.map (activity)->->
    queue.pageContent or= ""

    createActivityContent models, activity, (err, content)->
      if err
        console.error "activity not listed", err
        return queue.next()

      unless content
        # TODO Activity id can be added to error message
        console.error "content not found"
        return queue.next()

      pageContent = pageContent + content
      queue.next()

  queue.push ->
    callback null, pageContent

  daisy queue


getPagination = (currentPage, numberOfItems, itemsPerPage, route="")->
  # This is the number of adjacent link around current page.
  # E.g. let current page be 9, then pagination will look like this:
  # First Prev ... 4 5 6 7 8 9 10 11 12 13 14 ... Next Last
  # (Except 3-dots, they are useless for bots.)
  PAGERWINDOW = 4

  numberOfPages = Math.ceil(numberOfItems / itemsPerPage)
  firstLink = prevLink = nextLink = lastLink = ""

  if currentPage > 1
    firstLink = getSinglePageLink 1, "First", route
    prevLink  = getSinglePageLink (currentPage - 1), "Prev", route

  if currentPage < numberOfPages
    lastLink  = getSinglePageLink numberOfPages, "Last", route
    nextLink  = getSinglePageLink (currentPage + 1), "Next", route

  pagination = firstLink + prevLink

  start = 1
  end = numberOfPages

  start = currentPage - PAGERWINDOW  if currentPage > PAGERWINDOW

  if currentPage + PAGERWINDOW < numberOfPages
    end   = currentPage + PAGERWINDOW

  if start > 1
    pagination += getNoHrefLink " ... "

  [start..end].map (pageNumber)->
    pagination += getSinglePageLink pageNumber, null, route

  if end < numberOfPages
    pagination += getNoHrefLink " ... "

  pagination += nextLink
  pagination += lastLink

  return pagination

getNoHrefLink = (linkText)->
  "<a href='#'>#{linkText}  </a>"

getSinglePageLink = (pageNumber, linkText=pageNumber, route)->
  link = "<a href='#{uri.address}/#{route}?page=#{pageNumber}'>#{linkText}  </a>"
  return link

appendDecoratedTopic = (tag, queue)->
  queue.pageContent += createTagNode tag
  queue.next()

getSchemaOpeningTags = (contentType) ->
  openingTag = ""
  title = ""
  switch contentType
    when "post"
      title = "activities"
      openingTag += """<article itemscope itemtype="http://schema.org/BlogPosting">"""
    when "topic"
      title = "topics"

  openingTag +=
      """
          <div itemscope itemtype="http://schema.org/ItemList">
            <meta itemprop="mainContentOfPage" content="true"/>
            <h2 itemprop="name" class="hidden">Latest #{title}</h2>
            <meta itemprop="itemListOrder" content="Descending" />
      """

  return openingTag

getSchemaClosingTags = (contentType) ->
  closingTag = "</div>"
  closingTag += "</article>"  if contentType is "post"

  return closingTag

createTagNode = (tag)->
  tagContent = ""
  return tagContent  unless tag.title
  """
  <div class="kdview kdlistitemview kdlistitemview-topics topic-item">
    <header>
      <h3 class="subview">
        <a href="#{uri.address}/Activity?tagged=#{tag.slug}">
          <span itemprop="itemListElement">#{tag.title}</span>
        </a>
      </h3>
    </header>
    <div class="stats">
      <a href="#"><span>#{tag.counts?.post ? 0}</span> Posts</a>
      <a href="#"><span>#{tag.counts?.followers ? 0}</span> Followers</a>
    </div>
    <article>#{encoder.XSSEncode(tag.body) ? ''}</article>
  </div>
  """

getSidebar = ->
  """
  <aside id="main-sidebar" class="static">
    <div class="logo-wrapper">
      <a href="/"><figure></figure></a>
    </div>
    <div class="kdcustomscrollview">
      <main class="kdview kdscrollview">
        <div class="activity-sidebar">
          <section class="followed topics">
            <h3 class="sidebar-title">Channels</h3>
            <a class="kdlistitemview-sidebar-item clearfix" href="/Activity/Public"><span class="ttag">public</span></a>
            <a class="kdlistitemview-sidebar-item clearfix" href="/Activity/Announcement/changelog"><span class="ttag">changelog</span></a>
          </section>
          <section class='sidebar-join'>
            Join our growing community of developers from all over the world who
            are building awesome applications on their full-featured, cloud-based
            development environment powered by Koding.
            <form action="/Register">
              <button type="submit" class="kdbutton solid green medium">
                <span class="button-title">Sign Up</span>
              </button>
            </form>
            <a href="/Login" class='login-link'>Login</a>
          </section>
          <section class='sidebar-bottom-links'>
            <a href='http://koding.com/Features'>Features</a>
            <a href='http://learn.koding.com/'>Koding University</a>
          </section>
        </div>
      </main>
    </div>
  </aside>
  """

getEmptyPage = (channelName) ->
  content  = getChannelTitleContent channelName
  content += "<div class='no-item-found'>There is no activity.</div>"

  putContentIntoFullPage content, ""

putContentIntoFullPage = (content, pagination, graphMeta)->
  getGraphMeta  = require './graphmeta'
  analytics     = require './analytics'

  graphMeta = getGraphMeta graphMeta

  """
  <!DOCTYPE html>
  <html lang="en">
  <head>
    #{graphMeta}
  </head>
  <body itemscope itemtype="http://schema.org/WebPage" class="super activity">
    <div id="kdmaincontainer" class="kdview with-sidebar">
      #{getSidebar()}
      <section id="main-panel-wrapper" class="kdview">
        <div class="kdview kdtabpaneview activity clearfix content-area-pane active">
          <div id="content-page-activity" class="kdview content-page activity activity-pane clearfix">
            <main class="kdview kdscrollview kdtabview app-content">
              #{content}
              <nav class="crawler-pagination clearfix">
                #{pagination}
              </nav>
            </main>
          </div>
        </div>
      </section>
    </div>
    #{analytics()}
    <script>
      (function(d) {
        var config = {
          kitId: 'rbd0tum',
          scriptTimeout: 3000
        },
        h=d.documentElement,t=setTimeout(function(){h.className=h.className.replace(/\bwf-loading\b/g,"")+" wf-inactive";},config.scriptTimeout),tk=d.createElement("script"),f=false,s=d.getElementsByTagName("script")[0],a;h.className+=" wf-loading";tk.src='//use.typekit.net/'+config.kitId+'.js';tk.async=true;tk.onload=tk.onreadystatechange=function(){a=this.readyState;if(f||a&&a!="complete"&&a!="loaded")return;f=true;clearTimeout(t);try{Typekit.load(config)}catch(e){}};s.parentNode.insertBefore(tk,s)
      })(document);
    </script>
  </body>
  </html>
  """


module.exports = {
  buildContent
  createFeed
  createProfileContent
  putContentIntoFullPage
  getSidebar
  getEmptyPage
}
