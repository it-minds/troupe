# OpenBao for a plane-light: one node, a file backend on a volume, no TLS on a network
# only the stack's own containers are on. `entrypoint.sh` initialises and unseals it.
ui = false
disable_mlock = true

storage "file" {
  path = "/openbao/file"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}

api_addr = "http://openbao:8200"
