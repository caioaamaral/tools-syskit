# frozen_string_literal: true

require "async/io"
require "concurrent/hash"

module Syskit
    module RobyApp
        module Spawn
            # @api private
            #
            # Implementation of Syskit's process server
            #
            # The process server is the mean through which Syskit starts and
            # monitors deployments. Unless told otherwise, Syskit automatically
            # starts a process server on localhost. Other process servers are
            # declared using {Configuration#connect_to_process_server}, available
            # under Syskit.conf
            class Server
                extend Logger::Root("Syskit::RobyApp::ProcessServer", Logger::INFO)

                COMMAND_HANDLERS = {
                    "I" => :system_info,
                    "D" => :server_pid,
                    "C" => :create_log_dir,
                    "S" => :process_start,
                    "P" => :process_poll_exit,
                    "E" => :process_end,
                    "Q" => :quit
                }.freeze

                DEFAULT_PORT = 52_000

                def initialize(
                    loader: self.class.create_pkgconfig_loader,
                    name_service_ip: "localhost"
                )
                    @loader = loader
                    @name_service_ip = name_service_ip
                    @processes = {}
                end

                def run(port = DEFAULT_PORT, host: "0.0.0.0")
                    endpoint = Async::IO::Endpoint.parse("tcp://#{host}:#{port}")
                    Async do |task|
                        endpoint.accept do |peer|
                            main_client_loop(task, peer)
                        ensure
                            peer.close
                        end
                    ensure
                        endpoint.close
                    end
                end

                # @api private
                #
                # Main loop for a single client within an Async reactor
                def main_client_loop(task, peer)
                    loop do
                        command, args = read_message(peer)

                        task.async do
                            reply = send(COMMAND_HANDLERS.fetch(command), task, *args)
                            send_reply(peer, command, true, reply)
                        rescue StandardError => e
                            send_reply(peer, command, false, e.message)
                        end
                    end
                end

                # @api private
                #
                # Read one command from the remote peer
                def read_message(peer)
                    size = peer.read(4).unpack("L<")
                    Marshal.safe_load(peer.read(size))
                end

                # @api private
                #
                # Send a reply to the remote peer
                def send_reply(peer, command, error, reply)
                    reply = Marshal.dump({ command: command, error: error, value: reply })
                    size = [4 + reply.size].pack("L<")
                    peer.write(size)
                    peer.write(reply)
                end

                # The default name service IP used when spawning children
                #
                # @return [String]
                attr_reader :name_service_ip

                # Return information about available projects, typekits and deployments
                def system_info(_task)
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

                # Return the server PID
                def server_pid(_task)
                    [::Process.pid]
                end

                # Create a new log directory
                #
                # This is usually done when a new Syskit instance connects to the
                # server
                def create_log_dir(_task, log_dir, time_tag, metadata = {})
                    # We use this really only for log creation code
                    app = Roby::Application.new
                    app.log_base_dir = log_dir if log_dir
                    app_setup_from_metadata(app, metadata)
                    app.find_and_create_log_dir(time_tag)
                    output_log_dir_creation(metadata)
                end

                # @api private
                #
                # Configure a roby application instance based on given metadata
                def app_setup_from_metadata(_task, app, metadata)
                    if (parent_info = metadata["parent"])
                        if (app_name = parent_info["app_name"])
                            app.app_name = app_name
                        end
                        if (robot_name = parent_info["robot_name"])
                            app.robot(robot_name, info["robot_type"] || robot_name)
                        end
                    end

                    app.add_app_metadata(metadata)
                end

                # @api private
                #
                # Output log information about a newly created log directory
                def output_log_dir_creation(app, metadata)
                    if (parent_info = metadata["parent"])
                        ::Robot.info "created #{app.log_dir} on behalf of"
                        YAML.dump(parent_info).each_line do |line|
                            ::Robot.info "  #{line.chomp}"
                        end
                    else
                        ::Robot.info "created #{app.log_dir}"
                    end
                end

                # The shared library that must be preloaded to enable LTTng tracing
                def self.tracing_library_path
                    File.join(
                        Utilrb::PkgConfig.new("orocos-rtt-#{OroGen.orocos_target}")
                                         .libdir,
                        "liborocos-rtt-traces-#{OroGen.orocos_target}.so"
                    )
                end

                StartedProcess = Struct.new :pid, :child_process

                # Start a new deployment process
                def process_start(
                    task, name, deployment_name, name_mappings = {},
                    gdb: false, valgrind: false, log_level: :info,
                    tracing: false, name_service_ip: self.name_service_ip
                )
                    child_process = process_create(
                        name, deployment_name, name_mappings,
                        log_level: log_level,
                        tracing: tracing, name_service_ip: name_service_ip
                    )
                    process_apply_transform(child_process, "gdb", gdb)
                    process_apply_transform(child_process, "valgrind", valgrind)

                    pid = process.spawn
                    @processes[pid] = process

                    task.async { process.wait }
                    process.object_id
                end

                # Poll for process exit
                def process_poll_exit
                    result = []
                    @processes.delete_if do |_pid, process|
                        if process.exit_status
                            result << [process.object_id, process.exit_status]
                            true
                        end
                    end

                    result
                end

                # Create a ChildProcess object from the arguments passed to
                # process_start
                def process_create(
                    name, deployment_name, name_mappings = {},
                    log_level: :info, tracing: false,
                    name_service_ip: self.name_service_ip
                )
                    unless (bin_path = @loader.find_deployment_binfile(deployment_name))
                        raise ArgumentError,
                              "cannot find binary file from #{deployment_name}"
                    end

                    env = {}
                    env["LD_PRELOAD"] = self.class.tracing_library_path if tracing
                    env["BASE_LOG_LEVEL"] = resolve_log_level(log_level)
                    env["ORBInitRef"] = "NameService=corbaname::#{name_service_ip}"

                    arguments = []
                    arguments.concat(
                        name_mappings.map { |from, to| "--rename=#{from}:#{to}" }
                    )

                    ChildProcess.new(app.log_dir, name, env, bin_path, arguments)
                end

                # Apply a child process transform if enabled
                #
                # This is a helper for {#process_start}
                #
                # @param [ChildProcess] child_process
                # @param [String] name the name of the transformation to apply
                # @param [Boolean,Hash] flag_or_options either a flag saying whether
                #   the transform should be applied at all, or an options hash that
                #   should be passed to the transform
                # @return [ChildProcess]
                def process_apply_transform(child_process, name, flag_or_options)
                    return child_process unless flag_or_options

                    options = flag_or_options.kind_of?(Hash) ? flag_or_options : {}
                    ChildProcess.transform(child_process, name, options)
                end

                LOG_LEVELS = %I[debug info warn error fatal disable].freeze

                # Validate and normalize the log_level argument to {#process_start}
                def resolve_log_level(level)
                    unless LOG_LEVELS.include?(level)
                        raise ArgumentError,
                              "'#{level}' is not a valid log level. " \
                              "Valid ones are: #{LOG_LEVELS}."
                    end

                    level.to_s.upcase
                end

                # Helper method that stops all running processes
                def quit_and_join
                    Server.warn "Process server quitting"
                    Server.warn "Killing running deployments"

                    @processes.each_value do |p|
                        p.kill(:KILL) unless p.exit_status
                    end

                    @processes.each_value do |p|
                        p.wait unless p.exit_status
                    end
                    @processes.clear
                end
            end
        end
    end
end
