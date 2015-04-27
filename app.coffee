redis = require('redis')
WebSocket = require('ws')
request = require('superagent')

redis_port = process.env["REDIS_PORT_6379_TCP_PORT"] || 6379
redis_host = process.env["REDIS_PORT_6379_TCP_ADDR"] || '127.0.0.1'

slack_bot = process.env["SLACK_BOT"]
slack_user = process.env["SLACK_USER"]
slack_bot_token = process.env["SLACK_BOT_TOKEN"]
slack_user_token = process.env["SLACK_USER_TOKEN"]

endpoint = process.env["ENDPOINT"]
endpoint_key = process.env["ENDPOINT_KEY"]

user_slug = process.env["USER_SLUG"]

bitly_token = process.env["BITLY_TOKEN"]

slack = (method, role, payload, callback) ->
  token = if role == "bot"
    slack_bot_token
  else if role == "user"
    slack_user_token

  request
    .post("https://slack.com/api/#{method}")
    .type('form')
    .send(token: token)
    .send(payload)
    .end (err, result) ->
      if err
        callback?(err, null)
      else
        if result.body.ok
          callback?(null, result.body)
        else
          callback?(result.body.error, null)

findOrCreateGroup = (number, name, callback) ->
  slack "groups.list", "user", {exclude_archived: true}, (err, result) ->
    for group in result.groups when group.purpose.value == number
        return callback(null, group.id)

    slack "groups.create", "user", {name}, (err, result) ->
      group_id = result.group.id

      slack "groups.setPurpose", "user", {channel: group_id, purpose: number}, (err, result) ->
        slack "groups.invite", "user", {channel: group_id, user: slack_bot}, (err, result) ->
          callback(null, group_id)

processIncomingMessage = (message, contact) ->
  name = contact?[0] || message.from.substring(1)
  photo = contact?[2] || "http://lorempixel.com/48/48/"

  request
    .get('https://api-ssl.bitly.com/v3/shorten')
    .query(access_token: bitly_token, longUrl: photo)
    .end (err, result) ->
      findOrCreateGroup message.from, name, (err, group_id) ->
        options =
          channel: group_id
          text: message.text
          username: name
          icon_url: result.body.data.url
        slack "chat.postMessage", "bot", options

consumer = redis.createClient(redis_port, redis_host)
consumer.on 'message', (channel, message) ->
  {message, contact} = JSON.parse(message)
  processIncomingMessage(message, contact)

consumer.subscribe('messages')

slack "rtm.start", "bot", {}, (err, result) ->
  ws = new WebSocket(result.url)

  ws.on 'error', (error) ->
    console.dir(error)

  ws.on 'close', (code, message) ->
    console.dir({code, message})
    process.exit(1)

  ws.on 'message', (message) ->
    {type, channel, user, text, hidden} = JSON.parse(message)

    return if hidden || !(type == "message" && user == slack_user)

    text = text
      .replace(/&amp;/g, "&")
      .replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">")

    slack "groups.list", "user", {exclude_archived: true}, (err, result) ->
      for group in result.groups when group.id == channel
        return request
          .post(endpoint)
          .set('Accept', 'application/json')
          .set('X-XMPP-Key', endpoint_key)
          .send(to: group.purpose.value, text: text, user: user_slug)
          .end()
