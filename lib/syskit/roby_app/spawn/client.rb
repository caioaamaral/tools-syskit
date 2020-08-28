module Syskit
    module RobyApp
        module Spawn
            # @api private
            #
            # Client to {Server}
            class Client
                # @api private
                #
                # Internal eventmachine connection to the server
                class Connection < EventMachine::Connection
                    def initialize(client)
                        @client = client
                        super()
                    end

                    def post_init
                        # Connected
                        @client.connected
                    end

                    def unbind
                        # Connected
                        @client.disconnected
                    end
                end

                def initialize(host, port)
                    @connected = Concurrent::AtomicBoolean.new
                    EM.schedule do
                        @connection = EM.connect host, port, Connection, self
                    end
                end

                def connected?
                    @connected.true?
                end

                def connected
                    @connected.make_true
                end

                def disconnected
                    @connected.make_false
                end

                def disconnect
                    EM.schedule do
                        @connection.close_connection
                    end
                end
            end
        end
    end
end
