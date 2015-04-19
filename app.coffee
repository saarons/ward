redis = require('redis')
WebSocket = require('ws')
request = require('superagent')

redis_port = process.env["REDIS_PORT_6379_TCP_PORT"] || 6379
redis_host = process.env["REDIS_PORT_6379_TCP_ADDR"] || '127.0.0.1'

slack_bot = process.env["SLACK_BOT"]
slack_bot_token = process.env["SLACK_BOT_TOKEN"]
slack_user_token = process.env["SLACK_USER_TOKEN"]

endpoint = process.env["ENDPOINT"]
endpoint_key = process.env["ENDPOINT_KEY"]

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
        callback(err, null)
      else
        if result.body.ok
          callback(null, result.body)
        else
          callback(result.body.error, null)

findOrCreateGroup = (number, name, callback) ->
  slack "groups.list", "user", {exclude_archived: true}, (err, result) ->
    for group in result.groups
      if group.purpose.value == number
        return callback(null, group.id)

    slack "groups.create", "user", {name}, (err, result) ->
      group_id = result.group.id

      slack "groups.setPurpose", "user", {channel: group_id, purpose: number}, (err, result) ->
        slack "groups.invite", "user", {channel: group_id, user: slack_bot}, (err, result) ->
          callback(null, group_id)

processIncomingMessage = (message, contact) ->
  name = contact?[0] || message.to.substring(1)
  photo = contact?[2] || "http://lorempixel.com/48/48/"

  findOrCreateGroup message.to, name, (err, group_id) ->
    slack "chat.postMessage", "bot", {channel: group_id, text: message.text, username: name, icon_url: photo}

consumer = redis.createClient(redis_port, redis_host)
consumer.on 'message', (channel, message) ->
  {message, contact} = JSON.parse(message)
  processIncomingMessage(message, contact)

consumer.subscribe('messages')

slack "rtm.start", "bot", {}, (err, result) ->
  ws = new WebSocket(result.url)
  ws.on 'message', (message) ->
    {type, channel, user, text} = JSON.parse(message)

    return unless type == "message" && user != slack_bot

    slack "groups.list", "user", {exclude_archived: true}, (err, result) ->
      for group in result.groups when group.id == channel
        request
          .post(endpoint)
          .set('Accept', 'application/json')
          .set('X-XMPP-Key', endpoint_key)
          .send(to: group.purpose.value, text: text)
          .end()
