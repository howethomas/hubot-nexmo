{Adapter,TextMessage,Robot} = require '../../hubot'

url = require 'url'
http = require 'http'
express = require 'express'
Events = require 'events'
Emitter = Events.EventEmitter

class Nexmo extends Adapter
  constructor: (robot) ->
    super(robot)
    @ee= new Emitter
    @robot = robot
    @ee.on("MsgRx", (user_name, message_id, room_name, msg) =>
      user = @robot.brain.userForId user_name, name: user_name, room: room_name
      inbound_message = new TextMessage user, msg, 'MessageId'
      @robot.receive inbound_message
      console.log "Received from #{user_name} to #{room_name}: #{msg}"
    )

  key= process.env.NEMXO_KEY or '43291ed6'
  secret= process.env.NEXMO_SECRET or '8bb7490a'
  default_nexmo_params = 
    protocol: "http:"
    host: "rest.nexmo.com"
    pathname: "/sms/json"
    query:
      api_key: key
      api_secret: secret

  send_nexmo: (to, from, text) ->
    uri = url.format default_nexmo_params
    uri.query.to = to
    uri.query.from = from
    uri.query.text = text
    
    http.get
      uri: uri,
      (err, res, body) ->
      if err
        console.log err
      else
        ress = JSON.parse(body)
        if ress.messages[0].status > 0
          console.log ress.messages[0]["error-text"]
        else
          console.log {
            id: ress.messages[0]["message-id"]
            price: ress.messages[0]["message-price"]
            balance: ress.messages[0]["remaining-balance"]
          }
 
  set_callback: (callback_path) ->
    callback_params = default_nexmo_params
    callback_params.pathname = "/number/update"
    callback_params.query.country = "US"
    callback_params.query.msisdn = "5084707170"
    callback_params.query.moHttpUrl = callback_path
    uri = url.format callback_params
    
    http.request
      method: 'POST',
      uri: uri

  send: (envelope, strings...) ->
    {user, room} = envelope
    user = envelope if not user # pre-2.4.2 style
    from = user.room 
    to = user.name
    send_nexmo(to, from, string) for string in strings

  emote: (envelope, strings...) ->
    @send envelope, "* #{str}" for str in strings

  reply: (envelope, strings...) ->
    strings = strings.map (s) -> "#{envelope.user.name}: #{s}"
    @send envelope, strings...

  run: ->
    self = @
    listen_port = process.env.CALLBACK_PORT or 8888
    routable_address = process.env.CALLBACK_URL or "http://66.31.88.108:#{listen_port}"
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

    @set_callback callback_url  

exports.use = (robot) ->
  new Nexmo robot

