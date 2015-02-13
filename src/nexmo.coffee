{Adapter,TextMessage,Robot} = require '../../hubot'

url = require 'url'
http = require 'http'
express = require 'express'
Events = require 'events'
Emitter = Events.EventEmitter
Redis = require "redis"
Os = require("os")
Request = require('request')
ReadWriteLock = require('rwlock')
Us = require('underscore')

class Nexmo extends Adapter

  constructor: (robot) ->
    super(robot)
    @active_numbers = []
    @ee= new Emitter
    @robot = robot
    @ee.on("MsgRx", (user_name, message_id, room_name, msg) =>
      user = @robot.brain.userForId user_name, name: user_name, room: room_name
      inbound_message = new TextMessage user, msg, 'MessageId'
      @robot.receive inbound_message
    )
    @key= process.env.NEXMO_KEY
    @secret= process.env.NEXMO_SECRET
    @THROTTLE_RATE_MS = 1000
    @NEXMO_SEND_MSG_URL = "http://rest.nexmo.com/sms/json"
    @NEXMO_UPDATE_NUMBER_URL = "http://rest.nexmo.com/number/update"
    @throttled_nexmo = Us.throttle(@post_to_nexmo, @THROTTLE_RATE_MS)

    # Run a one second loop that checks to see if there are messages to be sent
    # to nexmo. Wait one second after the request is made to avoid
    # rate throttling issues.

  post_to_nexmo: (url, options, release) =>
    Request.post(
      url,
      options,
      (error, response, body) =>
        @last_nexmo_request = Date.now()
        release() if release?
    )

  send_nexmo_message: (to, from, text) ->
    options =
      qs:
        api_key: @key
        api_secret: @secret
        country: "US"
        to: message.to
        from: message.from
        text: message.text
    @throttled_nexmo(@NEXMO_SEND_MSG_URL, options)

  set_callback: (number, country, callback_path) =>
    options =
      qs:
        api_key: @key
        api_secret: @secret
        country: "US"
        msisdn: number
        moHttpUrl: callback_path
    @throttled_nexmo(@NEXMO_UPDATE_NUMBER_URL, options)

  send: (envelope, strings...) ->
    {user, room} = envelope
    user = envelope if not user # pre-2.4.2 style
    from = user.room
    to = user.name
    @send_nexmo_message(to, from, string) for string in strings

  emote: (envelope, strings...) ->
    @send envelope, "* #{str}" for str in strings

  reply: (envelope, strings...) ->
    strings = strings.map (s) -> "#{envelope.user.name}: #{s}"
    @send envelope, strings...

  run: ->
    self = @
    callback_path = process.env.NEXMO_CALLBACK_PATH or "/nexmo_callback"
    listen_port = process.env.NEXMO_LISTEN_PORT
    routable_address = process.env.NEXMO_CALLBACK_URL

    callback_url = "#{routable_address}#{callback_path}"
    app = express()
    app.get callback_path, (req, res) =>
      # First, see if this user is in the system.
      # If not, then let's make a new user for this far end.
      #
      res.writeHead 200,     "Content-Type": "text/plain"
      res.write "Message received"
      res.end()
      if req.query.msisdn?
        user_name = user_id = req.query.msisdn
        message_id = req.query.messageId
        room_name = req.query.to
        @ee.emit("MsgRx", user_name, message_id, room_name, req.query.text)
      return

    server = app.listen(listen_port, ->
      host = server.address().address
      port = server.address().port
      console.log "Nexmo listening locally at http://%s:%s", host, port
      console.log "External URL is #{callback_url}"
      return
    )

    @emit "connected"

    # Go through all of the active numbers, and add them.
    redis_client = Redis.createClient()
    redis_client.smembers("NEXMO_NUMBERS",
      (err, reply) =>
        for number in reply
          @set_callback number, "US", callback_url
          @active_numbers.push number
      )

exports.use = (robot) ->
  new Nexmo robot
