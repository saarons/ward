WebSocket = require('ws')
winston = require('winston')
express = require('express')
emojione = require('emojione')
request = require('superagent')
Pusher = require('pusher-client')
bodyParser = require('body-parser')

logger = new winston.Logger
  transports: [
    new winston.transports.Console
      prettyPrint: true
      level: process.env["LOG_LEVEL"]
  ]

BITLY_TOKEN = process.env["BITLY_TOKEN"]

SLACK_BOT = process.env["SLACK_BOT"]
SLACK_USER = process.env["SLACK_USER"]
SLACK_BOT_TOKEN = process.env["SLACK_BOT_TOKEN"]
SLACK_USER_TOKEN = process.env["SLACK_USER_TOKEN"]
SLACK_TOKEN = process.env["SLACK_TOKEN"]

USER_SLUG = process.env["USER_SLUG"]
USER_NUMBER = process.env["USER_NUMBER"]
USER_TOKEN = process.env["USER_TOKEN"]
USER_PHOTO_TOKEN = process.env["USER_PHOTO_TOKEN"]

slack = (method, role, payload, callback) ->
  token = if role == "bot"
    SLACK_BOT_TOKEN
  else if role == "user"
    SLACK_USER_TOKEN

  request
    .post("https://slack.com/api/#{method}")
    .type('form')
    .send(token: token)
    .send(payload)
    .end (err, result) ->
      if err
        logger.log('error', 'Slack error', err)

        callback?(err, null)
      else
        if result.body.ok
          callback?(null, result.body)
        else
          logger.log('error', 'Slack error', result.body.error)

          callback?(result.body.error, null)

findOrCreateGroup = (number, name, callback) ->
  slack "groups.list", "user", {exclude_archived: true}, (err, result) ->
    for group in result.groups when group.purpose.value == number
      return callback(null, group.id)

    slack "groups.create", "user", {name}, (err, result) ->
      group_id = result.group.id

      slack "groups.setPurpose", "user", {channel: group_id, purpose: number}, (err, result) ->
        slack "groups.invite", "user", {channel: group_id, user: SLACK_BOT}, (err, result) ->
          callback(null, group_id)

processIncomingMessage = (payload) ->
  from = payload.feedable.from
  text = payload.feedable.text
  slug = payload.contact.external_slug
  name = payload.contact.external?.google?.name || from

  photo_url = "https://api.abbott.io/v1/contacts/#{slug}/photo?token=#{USER_PHOTO_TOKEN}"

  request
    .get('https://api-ssl.bitly.com/v3/shorten')
    .query(access_token: BITLY_TOKEN, longUrl: photo_url)
    .end (err, result) ->
      findOrCreateGroup from, name, (err, group_id) ->
        options =
          channel: group_id
          text: text
          username: name
          icon_url: result.body.data.url
        slack "chat.postMessage", "bot", options

processIncomingVoicemail = (payload) ->
  from = payload.feedable.from
  text = payload.feedable.text
  url = payload.feedable.voicemail
  slug = payload.contact.external_slug
  name = payload.contact.external?.google?.name || from

  photo_url = "https://api.abbott.io/v1/contacts/#{slug}/photo?token=#{USER_PHOTO_TOKEN}"

  request
    .get('https://api-ssl.bitly.com/v3/shorten')
    .query(access_token: BITLY_TOKEN, longUrl: photo_url)
    .end (err, result) ->
      findOrCreateGroup from, name, (err, group_id) ->
        attachments = JSON.stringify(
          [
            fallback: text
            text: text
            title: "Voicemail"
            title_link: url,
            pretext: "New voicemail from #{name}"
          ])

        options =
          channel: group_id
          username: name
          icon_url: result.body.data.url
          attachments: attachments

        slack "chat.postMessage", "bot", options

socket = new Pusher '42d6b0407dc69bdaf0b7',
  auth:
    headers:
      'Authorization': "Bearer #{USER_TOKEN}"
  authEndpoint: "https://api.abbott.io/v1/feed/subscribe"
  encrypted: true

getFeed = (id, callback) ->
  request
    .get("https://api.abbott.io/v1/feed/#{id}")
    .set('Accept', 'application/json')
    .set('Authorization', "Bearer #{USER_TOKEN}")
    .end (err, result) ->
      if err
        logger.log('error', 'Feed Retrieval Error', err)

        callback(err)
      else
        logger.log('debug', 'From Server', result.body)

        callback(null, result.body)

channel = socket.subscribe "private-#{USER_SLUG}"

channel.bind 'messages', (data) ->
  logger.log('debug', 'Received Inbound Message', data)

  getFeed data.id, (err, data) ->
    if !err
      processIncomingMessage(data)

channel.bind 'voicemails', (data) ->
  logger.log('debug', 'Received Inbound Voicemail', data)

  getFeed data.id, (err, data) ->
    if !err
      processIncomingVoicemail(data)

slack "rtm.start", "bot", {}, (err, result) ->
  ws = new WebSocket(result.url)

  ws.on 'error', (error) ->
    logger.log('error', 'WebSocket error', error)

  ws.on 'close', (code, message) ->
    logger.log('error', 'WebSocket connection closed', {code, message})
    process.exit(1)

  ws.on 'message', (message) ->
    message = JSON.parse(message)

    logger.log('debug', 'Received Outbound Message', message)

    {type, subtype, channel, user, text} = message

    return unless type == "message" && user == SLACK_USER && !subtype?

    text = text
      .replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">")
      .replace(/&amp;/g, "&")

    text = emojione.unifyUnicode(text)

    slack "groups.list", "user", {exclude_archived: true}, (err, result) ->
      for group in result.groups when group.id == channel
        to = group.purpose.value
        payload = {to, text, from: USER_NUMBER}

        logger.log('debug', 'Sent Message', payload)

        request
          .post('https://api.abbott.io/v1/messages')
          .set('Accept', 'application/json')
          .set('Authorization', "Bearer #{USER_TOKEN}")
          .send(payload)
          .end()

        return


app = express()
app.use(bodyParser.urlencoded({ extended: false }))

app.post '/calls', (req, res) ->
  logger.log('debug', 'Received Call Request', req.body)

  if req.body.token == SLACK_TOKEN && req.body.user_id == SLACK_USER
    slack "groups.info", "user", {channel: req.body.channel_id}, (err, result) ->
      if !err
        request
          .post('https://api.abbott.io/v1/calls')
          .set('Accept', 'application/json')
          .set('Authorization', "Bearer #{USER_TOKEN}")
          .send({to: result.group.purpose.value})
          .end()

  res.status(200).end()

app.listen(3000)
