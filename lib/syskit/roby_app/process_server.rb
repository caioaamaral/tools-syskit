# frozen_string_literal: true

require "syskit/roby_app/"

module Syskit
    module RobyApp
        class ProcessServer
            extend Logger::Root("Syskit::RobyApp::ProcessServer", Logger::INFO)

            COMMAND_GET_INFO   = "I"
            COMMAND_GET_PID    = "D"
            COMMAND_CREATE_LOG = "C"
            COMMAND_START      = "S"
            COMMAND_END        = "E"
            COMMAND_QUIT       = "Q"

            COMMAND_HANDLERS = {
                COMMAND_GET_INFO => :system_info,
                COMMAND_GET_PID => :server_pid,
                COMMAND_CREATE_LOG => :create_log_dir,
                COMMAND_START => :process_start,
                COMMAND_END => :process_end,
                COMMAND_QUIT => :quit
            }.freeze

            # @api private
            #
            # Handling of a client connection
            class ClientConnection < EventMachine::Connection
                def initialize(process_server)
                    super()

                    @process_server = process_server
                end

                def post_init
                    @process_server.handle_client_new(self)
                end

                def unbind
                    @process_server.handle_client_close(self)
                end

                def receive_data(data)
                    @current_data.concat(data)
                    return unless @current_data.size > 4

                    @packet_size ||= @current_data[0, 4].unpack("L<")
                    return if @current_data.size < @packet_size

                    command, args = Marshal.safe_load(@current_data[4, @packet_size - 4])
                    reply = @process_server.send(
                        COMMAND_HANDLERS.fetch(command), self, *args
                    )

                    reply = Marshal.dump(reply)
                    size = [4 + reply.size].pack("L<")
                    send_data(size)
                    send_data(reply)
                end
            end

            # @api private
            #
            # Management of a started process
            class ProcessWatch < EventMachine::ProcessWatch
                def initialize(process_server)
                    super()

                    @process_server = process_server
                end

                def process_exited
                    @process_server.handle_process_exit(pid)
                end
            end

            # The default name service IP used when spawning children
            #
            # @return [String]
            attr_reader :name_service_ip

            def initialize(
                app,
                loader: self.class.create_pkgconfig_loader,
                name_service_ip: "localhost"
            )
                @app = app
                @loader = loader
                @name_service_ip = name_service_ip
            end

            def system_info(_client)
                available_projects = {}
                available_typekits = {}
                available_deployments = {}
                @loader.each_available_project_name do |name|
                    available_projects[name] =
                        loader.project_model_text_from_name(name)
                end
                @loader.each_available_typekit_name do |name|
                    available_typekits[name] =
                        loader.typekit_model_text_from_name(name)
                end
                @loader.each_available_deployment_name do |name|
                    available_deployments[name] =
                        loader.find_project_from_deployment_name(name)
                end
                [available_projects, available_deployments, available_typekits]
            end

            def server_pid(_client)
                [::Process.pid]
            end

            def create_log_dir(_client, log_dir, time_tag, metadata = {})
                app.log_base_dir = log_dir if log_dir

                if parent_info = metadata["parent"]
                    if app_name = parent_info["app_name"]
                        app.app_name = app_name
                    end
                    if robot_name = parent_info["robot_name"]
                        app.robot(robot_name, parent_info["robot_type"] || robot_name)
                    end
                end

                app.add_app_metadata(metadata)
                app.find_and_create_log_dir(time_tag)
                if parent_info = metadata["parent"]
                    ::Robot.info "created #{app.log_dir} on behalf of"
                    YAML.dump(parent_info).each_line do |line|
                        ::Robot.info "  #{line.chomp}"
                    end
                else
                    ::Robot.info "created #{app.log_dir}"
                end
            end

            def process_start(
                name, deployment_name, name_mappings = {},
                gdb: false, valgrind: false, log_level: :info,
                name_service_ip: self.name_service_ip
            )
                unless (bin_path = @loader.find_deployment_binfile(deployment_name))
                    raise ArgumentError, "cannot find binary file from #{deployment_name}"
                end

                env = {}
                env["LD_PRELOAD"] = options[:tracing_library] if options[:tracing_library]
                env["BASE_LOG_LEVEL"] = resolve_log_level(log_level)
                env["ORBInitRef"] = "NameService=corbaname::#{name_service_ip}"

                process = ChildProcess.new()

                @processes[name] = EM.watch_process(pid, ProcessWatch, self)
            end

            LOG_LEVELS = %I[debug info warn error fatal disable].freeze

            # @api private
            #
            # Validate and normalize the log_level argument to {#process_start}
            def resolve_log_level(level)
                unless LOG_LEVELS.include?(log_level)
                    raise ArgumentError,
                          "'#{log_level}' is not a valid log level." +
                          " Valid options are #{LOG_LEVELS}."
                end

                result.env["BASE_LOG_LEVEL"] = log_level.to_s.upcase
            end

            # Helper method that stops all running processes
            def quit_and_join # :nodoc:
                Server.warn "Process server quitting"
                Server.warn "Killing running clients"
            end
        end
    end
end
