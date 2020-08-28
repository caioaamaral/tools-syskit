# frozen_string_literal: true

module Syskit
    module RobyApp
        module Spawn
            # @api private
            #
            # Encapsulation of spawning child processes and waiting on them
            class ChildProcess
                # The target working directory
                #
                # @return [String]
                attr_reader :working_directory

                # A name to reference the started process with
                #
                # This is for instance used to name log files
                #
                # @return [String]
                attr_reader :name

                # The environment
                #
                # Values that are arrays will be joined with the operating system's
                # path separator before spawning the child process
                #
                # @return [Hash]
                attr_accessor :env

                # The program file
                #
                # @return [String]
                attr_accessor :bin_path

                # The arguments
                #
                # @return [Array<String>]
                attr_accessor :arguments

                # The child process pid once spawned
                #
                # @return [Integer,nil]
                attr_reader :pid

                # The child's exit status
                attr_reader :exit_status

                def initialize(working_directory, name, env, bin_path, arguments)
                    @working_directory = working_directory
                    @name = name
                    @env = env
                    @bin_path = bin_path
                    @arguments = arguments
                end

                def dup
                    working_directory = self.working_directory.dup
                    env = self.env.dup.transform_values(&:dup)
                    arguments = self.arguments.map(&:dup)
                    self.class.new(
                        working_directory, name.dup, env, bin_path.dup, arguments
                    )
                end

                # Spawn the child process
                #
                # @return [Integer] the pid (also stored as {#pid})
                # @raise SpawnError if starting the child failed
                def spawn
                    raise SpawnError, "already spawned" if @pid

                    validate_substitutions

                    guard_r, child_pid = async_fork do
                        fork_child_setup_and_exec
                    end

                    if (msg = guard_r.read)
                        Process.waitpid(child_pid)
                        raise SpawnError, msg if msg
                    end

                    @pid = child_pid
                ensure
                    guard_r&.close
                end

                # @api private
                #
                # Validate that the required substitutions can be made
                def validate_substitutions
                    return unless name.include?(File::PATH_SEPARATOR)

                    env.each do |k, v|
                        if /%NAME%/.match?(v)
                            raise SpawnError,
                                  "cannot substitute %NAME% in environment variable "\
                                  "'#{k}', as the name '#{name}' contains the path "\
                                  "separator #{File::PATH_SEPARATOR}"
                        end
                    end
                end

                # @api private
                #
                # In-fork implementation compatible with async
                def async_fork
                    guard_r, guard_w = IO.pipe
                    guard_w.sync = true

                    pid = fork do
                        guard_r.close
                        yield
                    rescue Exception => e # rubocop:disable Lint/RescueException
                        guard_w.write(e.message)
                        exit!(1)
                    end

                    guard_w.close
                    [Async::IO::Generic.new(guard_r), pid]
                end

                # @api private
                #
                # Generic implementation of performing work in a thread in a
                # way that is compatible with Async's reactor
                def async_thread(interrupt: nil)
                    guard_r, guard_w = IO.pipe
                    guard_r = Async::IO::Generic.new(guard_r)

                    thread = Thread.new do
                        ret = yield
                        guard_w.close
                        ret
                    end

                    guard_r.read(1)
                    thread.value
                rescue Async::Stop
                    if interrupt
                        interrupt.call
                        thread.join
                    end
                ensure
                    guard_r.close
                    guard_w.close unless guard_w.closed?
                end

                # Wait for the process to finish
                #
                # @raise SpawnError if the process is not yet spawned
                def wait
                    raise SpawnError, "not yet spawned" unless @pid

                    @exit_status = async_thread(interrupt: proc { kill(:KILL) }) do
                        _, exit_status = ::Process.wait2(@pid)
                        exit_status
                    end
                end

                # Kill a running process
                #
                # @raise SpawnError if the process is not yet spawned
                # @raise errors raised by Process.kill
                def kill(signal = :TERM)
                    raise SpawnError, "not yet spawned" unless @pid

                    ::Process.kill(signal, -@pid)
                end

                # Exception raised by {#spawn} if exec-ing the child failed
                class SpawnError < RuntimeError; end

                # @api private
                #
                # Implementation of what goes into the fork
                #
                # We do not use #spawn directly as we want to be able to setup
                # redirections or output files using the child's PID
                def fork_child_setup_and_exec
                    pid = ::Process.pid.to_s

                    exec_env = apply_env_substitutions(pid)
                    exec_arguments = apply_arguments_substitutions(pid)

                    out = self.class.output_file_path(working_directory, name, pid)
                    exec(
                        exec_env, bin_path, *exec_arguments,
                        out: out, err: [:child, 1],
                        close_others: true, chdir: working_directory
                    )
                end

                # @api private
                #
                # Return {env} with the internal variable substituted
                def apply_env_substitutions(pid)
                    pid = pid.to_s
                    env.transform_values do |v|
                        v = v.join(File::PATH_SEPARATOR) if v.respond_to?(:to_ary)
                        perform_substitution(v, pid)
                    end
                end

                # @api private
                #
                # Return {env} with the internal variable substituted
                def apply_arguments_substitutions(pid)
                    pid = pid.to_s
                    arguments.map { |v| perform_substitution(v, pid) }
                end

                # Path to the output file {ChildProcess} will create
                #
                # @return String
                def self.output_file_path(working_directory, name, pid)
                    File.join(working_directory, "#{name}-#{pid}.txt")
                end

                # Output file into which stdout and stderr are redirected
                #
                # @return String
                # @raise SpawnError if the method is called before #spawn
                def output_file_path
                    unless pid
                        raise SpawnError,
                              "#output_file_path cannot be called before #spawn"
                    end

                    self.class.output_file_path(working_directory, name, pid)
                end

                # @api private
                #
                # Substitute the %PID% and %NAME% patterns in the given value
                #
                # @param [String] value the string to perform substitution on
                # @param [String] pid the pid in string form
                def perform_substitution(value, pid)
                    value.gsub("%PID%", pid)
                         .gsub("%NAME%", name)
                end

                # Transform a command line
                #
                # @param [String] the filter name. Filters are method of Commandline
                #   named as filter_${filter_name}
                # @param [Commandline] commandline the command line to transform
                def self.transform(filter_name, commandline, **options)
                    commandline = commandline.dup
                    send("transform_#{filter_name}", commandline, **options)
                    commandline
                end

                # Transform a command line to run it under gdbserver
                def self.transform_gdb(
                    commandline, gdb_path: "gdbserver", gdb_port:, gdb_options: []
                )
                    commandline.arguments = [
                        *gdb_options, ":#{gdb_port}",
                        commandline.bin_path, *commandline.arguments
                    ]
                    commandline.bin_path = gdb_path
                end

                # Transform a command line to run it under valgrind
                def self.transform_valgrind(
                    commandline, valgrind_path: "valgrind", valgrind_options: []
                )
                    commandline.arguments =
                        ["--log-file=%NAME%-%PID%.valgrind.log",
                         *valgrind_options,
                         commandline.bin_path, "--"] + commandline.arguments
                    commandline.bin_path = valgrind_path
                end
            end
        end
    end
end
