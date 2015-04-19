redis = require('redis')
request = require('superagent')

redis_port = process.env["REDIS_PORT_6379_TCP_PORT"] || 6379
redis_host = process.env["REDIS_PORT_6379_TCP_ADDR"] || '127.0.0.1'

slack_bot = process.env["SLACK_BOT"]
slack_bot_token = process.env["SLACK_BOT_TOKEN"]
slack_user_token = process.env["SLACK_USER_TOKEN"]

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

      slack "groups.invite", "user", {channel: group_id, user: slack_bot}, (err, result) ->
        callback(null, group_id)

processIncomingMessage = (message, contact) ->
  name = if contact
    contact[0]
  else
    message.to.substring(1)

  findOrCreateGroup message.to, name, (err, group_id) ->
    slack "chat.postMessage", "bot", {channel: group_id, text: message.text, username: name, icon_url: 'http://lorempixel.com/48/48/'}

consumer = redis.createClient(redis_port, redis_host)
consumer.on 'message', (channel, message) ->
  {message, contact} = JSON.parse(message)
  processIncomingMessage(message, contact)

consumer.subscribe('messages')
