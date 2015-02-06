{Adapter,TextMessage,Robot} = require '../../hubot'

url = require 'url'
http = require 'http'
express = require 'express'
Events = require 'events'
Emitter = Events.EventEmitter
Redis = require "redis"
Os = require("os")


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
      console.log "Received from #{user_name} to #{room_name}: #{msg}"
    )

  key= process.env.NEMXO_KEY 
  secret= process.env.NEXMO_SECRET 

  send_nexmo: (to, from, text) ->
    nexmo_params = 
      protocol: "http:"
      host: "rest.nexmo.com"
      pathname: "/sms/json"
      query:
        api_key: key
        api_secret: secret
        to: to
        from: from
        text: text
    uri = url.format nexmo_params
    http.get(uri, (res) ->
      console.log "Got response: " + res.statusCode
      return
      ).on "error", (e) ->
        console.log "Got error: " + e.message
        return
   
  set_callback: (number, country, callback_path) ->
    nexmo_params = 
      protocol: "http:"
      host: "rest.nexmo.com"
      pathname: "/number/update"
      query:
        api_key: key
        api_secret: secret
        country: "US"
        msisdn: number
        moHttpUrl: callback_path
    uri = url.format nexmo_params
    http.request
      method: 'POST',
      uri: uri

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
    routable_address = process.env.CALLBACK_URL 
    callback_path = process.env.CALLBACK_PATH or "/nexmo_callback"
    callback_url = "#{routable_address}#{callback_path}"
    app = express()
    
    app.get callback_path, (req, res) =>
      # First, see if this user is in the system.
      # If not, then let's make a new user for this far end.
      #

      res.writeHead 200,     "Content-Type": "text/plain"
      res.write "Message received"
      res.end()
      user_name = user_id = req.query.msisdn
      message_id = req.query.messageId
      room_name = req.query.to
      @ee.emit("MsgRx", user_name, message_id, room_name, req.query.text)
      return

    server = app.listen(listen_port, =>
      host = server.address().address
      port = server.address().port
      console.log "Nexmo listening locally at http://%s:%s", host, port
      console.log "External URL is #{callback_url}"
      return
    )

    # Go through all of the active numbers, and add them.
    redis_client = Redis.createClient()
    redis_client.smembers("NEXMO_NUMBERS", 
      (err, reply) ->
        for number in reply
          @set_callback number, "US", callback_url(number)
          @active_numbers.push number
      )
    @emit "connected"

exports.use = (robot) ->
  new Nexmo robot

