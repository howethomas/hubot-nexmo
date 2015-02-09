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
    @outbound_messages = []
    @nexmo_lock = new ReadWriteLock

    # Run a one second loop that checks to see if there are messages to be sent
    # to nexmo. Wait one second after the request is made to avoid
    # rate throttling issues.
    setInterval(
      () =>
        if @outbound_messages.length > 0
          @nexmo_lock.writeLock("nexmo", (release)=>
            message = @outbound_messages.shift()
            console.log("Sending #{message.text} to #{message.to}")
            options =
              qs:
                api_key: @key
                api_secret: @secret
                country: "US"
                to: message.to
                from: message.from
                text: message.text
            Request.post("http://rest.nexmo.com/sms/json", options,
              (error, response, body) =>
                @nexmo_send_in_progress = false
            )
            # Release the semaphore so that somebody else can take it.
            release()
          )
      ,1000) # Run this loop ever second (1000 ms)

  send_nexmo: (to, from, text) ->
    message =
      to: to
      from: from
      text: text
    @outbound_messages.push message

  # Used to call Nexmo to set the call back URL for the
  # inbound messages.
  set_callback: (number, country, callback_path) =>
    console.log("Setting callback to #{number} as #{callback_path}")
    @nexmo_lock.writeLock("nexmo", (release) =>
      options =
        qs:
          api_key: @key
          api_secret: @secret
          country: "US"
          msisdn: number
          moHttpUrl: callback_path
      Request.post("http://rest.nexmo.com/number/update", options,
        (error, response, body) ->
          if (response.error_code isnt "200")
            console.log(body)
      )
      # Now that we have sent this out, wait a second so we don't
      # hit throttling.
      setTimeout(
        () ->
          release();
        ,1000); # Wait one second! (1000 ms)
    )


  send: (envelope, strings...) ->
    {user, room} = envelope
    user = envelope if not user # pre-2.4.2 style
    from = user.room
    to = user.name
    @send_nexmo(to, from, string) for string in strings

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
