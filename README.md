### What's this

Emulate `ssh -D`'s behavior even if port-forwarding is turned off in
`sshd_config`.

### Usage

Put `RemoteHandler` in remote machine, and run
`SimplServer USER HOST PATH-TO-REMOTEHANDLER` on local machine.

Default port to listen is 1080 and you could change it in SimplServer.hs
