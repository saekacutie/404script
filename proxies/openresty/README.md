# saeka-ssh

The OpenResty image exposes the SSH-over-WebSocket path `/saeka-ssh`.
The default SSH credentials are `saeka:saeka`; set `SSH_USER` and
`SSH_PASSWORD` in the deployment environment to replace them. This is an
HTTP upgrade wrapper around a local SSH session, not native SSH on Cloud Run.
