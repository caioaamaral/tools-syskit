# frozen_string_literal: true

require "async/io"
require "syskit/test/self"
require "syskit/roby_app/spawn/child_process"

module Syskit
    module RobyApp
        module Spawn
            describe ChildProcess do
                before do
                    @echo_bin_path =
                        %w[/usr/bin/echo /bin/echo].find { |p| File.file?(p) }
                    @sleep_bin_path =
                        %w[/usr/bin/sleep /bin/sleep].find { |p| File.file?(p) }

                    @workdir = make_tmpdir
                end

                it "starts the process" do
                    child_process = ChildProcess.new(
                        @workdir, "echo", {}, @echo_bin_path, []
                    )

                    task = Async do
                        pid = child_process.spawn
                        _, exit_status = Process.waitpid2(pid)
                        exit_status
                    end
                    refute task.failed?
                    assert task.result.success?
                end

                it "reports if the binary does not exist" do
                    child_process = ChildProcess.new(
                        @workdir, "echo", {}, "/does/not/exist", []
                    )

                    e = assert_async_raises(ChildProcess::SpawnError) do
                        child_process.spawn
                    end
                    assert_match(/No such file or directory/, e.message)
                end

                it "redirects the standard output to a file named "\
                    "${NAME}-${PID}.txt" do
                    child_process = run_child(
                        @workdir, "test-echo", {}, @echo_bin_path, ["test-42"]
                    )

                    result = child_output_lines(child_process)
                    assert_equal "test-42", result.first
                end

                it "redirects the standard error to a file named "\
                    "${NAME}-${PID}.txt" do
                    child_process = run_child(
                        @workdir, "test-echo", {},
                        "/bin/sh", ["-c", "#{@echo_bin_path} test-42 1>&2"]
                    )

                    result = child_output_lines(child_process)
                    assert_equal "test-42", result.first
                end

                it "allows to monitor the task" do
                    child_process = ChildProcess.new(
                        @workdir, "sleep", {}, @sleep_bin_path, ["1"]
                    )

                    before, executed, finished = nil
                    Async do |task|
                        before = Time.now
                        child_process.spawn
                        task.async do
                            child_process.wait
                            finished = Time.now
                        end

                        task.async do
                            executed = Time.now
                        end
                    end

                    assert (Time.now - before) > 1,
                            "expected the execution of 'sleep' to take at least 1s, "\
                            "got #{Time.now - before}"
                    assert executed < finished,
                            "expected the #wait call to finish before the concurrent "\
                            "async task (#{executed})"
                    assert child_process.exit_status.success?
                end

                it "passes the environment to the child" do
                    child_process = run_child(
                        @workdir, "test-env", { "some" => "value" },
                        find_standard_tool_path("env"), []
                    )

                    result = child_output_lines(child_process)
                    assert_includes result, "some=value"
                end

                it "joins array environment values with the paths separator" do
                    child_process = run_child(
                        @workdir, "test-env", { "some" => %w[first second] },
                        find_standard_tool_path("env"), []
                    )

                    result = child_output_lines(child_process)
                    assert_includes result, "some=first#{File::PATH_SEPARATOR}second"
                end

                it "substitutes %NAME% and %PID% in scalar environment values" do
                    child_process = run_child(
                        @workdir, "test", { "some" => "%NAME%-%PID%" },
                        find_standard_tool_path("env"), []
                    )

                    result = child_output_lines(child_process)
                    assert_includes result, "some=test-#{child_process.pid}"
                end

                it "substitutes %NAME% and %PID% in the array environment values" do
                    child_process = run_child(
                        @workdir, "test", { "some" => %w[%NAME% %PID%] },
                        find_standard_tool_path("env"), []
                    )

                    result = child_output_lines(child_process)
                    assert_includes(
                        result,
                        "some=test#{File::PATH_SEPARATOR}#{child_process.pid}"
                    )
                end

                it "rejects %NAME% substitutions if the name contains path separator" do
                    name = "test#{File::PATH_SEPARATOR}"
                    child_process = ChildProcess.new(
                        @workdir, name, { "some" => "%NAME%" },
                        find_standard_tool_path("env"), []
                    )
                    e = assert_async_raises(ChildProcess::SpawnError) do
                        child_process.spawn
                    end
                    assert_equal "cannot substitute %NAME% in environment "\
                                 "variable 'some', as the name '#{name}' contains "\
                                 "the path separator #{File::PATH_SEPARATOR}",
                                 e.message
                end


                describe "#dup" do
                    before do
                        @child_process = ChildProcess.new(
                            "workdir", "process_name",
                            { "envvar" => "some_value", "path_var" => ["some", "value"] },
                            "/path/to/bin", ["arg=value"]
                        )
                        @dup = @child_process.dup
                    end

                    it "creates a copy whose working copy is isolated" do
                        @dup.working_directory << "somestuff"
                        assert_equal "workdir", @child_process.working_directory
                    end

                    it "creates a copy whose name is isolated" do
                        @dup.name << "somestuff"
                        assert_equal "process_name", @child_process.name
                    end

                    it "creates a copy whose env is isolated" do
                        @dup.env["var"] = "somestuff"
                        refute @child_process.env.key?("var")
                    end

                    it "creates a copy whose env scalar value is isolated" do
                        @dup.env["envvar"] << "somestuff"
                        assert_equal "some_value", @child_process.env["envvar"]
                    end

                    it "creates a copy whose env path value is isolated" do
                        @dup.env["path_var"] << "somestuff"
                        assert_equal %w[some value], @child_process.env["path_var"]
                    end

                    it "creates a copy whose arguments array is isolated" do
                        @dup.arguments << "new"
                        assert_equal ["arg=value"], @child_process.arguments
                    end

                    it "creates a copy whose scalar arguments is isolated" do
                        @dup.arguments[0] << "somestuff"
                        assert_equal ["arg=value"], @child_process.arguments
                    end

                    it "creates a copy whose bin_path is isolated" do
                        @dup.bin_path << "somestuff"
                        assert_equal "/path/to/bin", @child_process.bin_path
                    end
                end

                def find_standard_tool_path(name)
                    ["/bin/#{name}", "/usr/bin/#{name}"].find { |p| File.file?(p) }
                end

                def assert_async_raises(error)
                    task = Async do
                        e = assert_raises(error) do
                            yield
                        end
                        [e]
                    end
                    task.wait.first
                end

                def run_child(*args, **kw)
                    child_process = ChildProcess.new(*args, **kw)
                    Async do
                        child_process.spawn
                        child_process.wait
                    end
                    child_process
                end

                def child_output_lines(child_process)
                    File.read(child_process.output_file_path).split.map(&:chomp)
                end

                describe ".transform_gdb" do
                    before do
                        @child_process = ChildProcess.new(
                            @workdir, "echo", { "some" => "env "},
                            @echo_bin_path, %w[some arg]
                        )
                    end

                    it "runs the command under gdbserver" do
                        child_process = ChildProcess.transform(
                            "gdb", @child_process, gdb_port: 3000
                        )
                        assert_equal "gdbserver", child_process.bin_path
                        assert_equal [":3000", @echo_bin_path, "some", "arg"],
                                     child_process.arguments
                    end

                    it "inserts gdbserver arguments before the comm argument" do
                        child_process = ChildProcess.transform(
                            "gdb", @child_process,
                            gdb_port: 3000, gdb_options: %w[--some --arg]
                        )
                        assert_equal ["--some", "--arg", ":3000",
                                      @echo_bin_path, "some", "arg"],
                                     child_process.arguments
                    end
                end

                describe ".transform_valgrind" do
                    before do
                        @child_process = ChildProcess.new(
                            @workdir, "echo", { "some" => "env "},
                            @echo_bin_path, %w[some arg]
                        )
                    end

                    it "runs the command under valgrind" do
                        child_process = ChildProcess.transform(
                            "valgrind", @child_process
                        )
                        assert_equal "valgrind", child_process.bin_path
                        assert_equal ["--log-file=%NAME%-%PID%.valgrind.log",
                                      @echo_bin_path, "--", "some", "arg"],
                                     child_process.arguments
                    end

                    it "inserts gdbserver arguments before the original command" do
                        child_process = ChildProcess.transform(
                            "valgrind", @child_process,
                            valgrind_options: %w[--some --arg]
                        )
                        assert_equal "valgrind", child_process.bin_path
                        assert_equal ["--log-file=%NAME%-%PID%.valgrind.log",
                                      "--some", "--arg",
                                      @echo_bin_path, "--", "some", "arg"],
                                     child_process.arguments
                    end
                end
            end
        end
    end
end
