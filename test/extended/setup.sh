#!/bin/bash
#
# This abstracts starting up an extended server.

# If invoked with arguments, executes the test directly.
function os::test::extended::focus () {
	if [[ $# -ne 0 ]]; then
		os::log::info "Running custom: $*"
		os::test::extended::test_list "$@"
		if [[ "${TEST_COUNT}" -eq 0 ]]; then
			os::log::error "No tests would be run"
			exit 1
		fi
		extended.test "$@"
		exit $?
	fi
}

# Launches an extended server for OpenShift
# TODO: this should be doing less, because clusters should be stood up outside
#		and then tests are executed.	Tests that depend on fine grained setup should
#		be done in other contexts.
function os::test::extended::setup () {
	# build binaries
	os::util::ensure::built_binary_exists 'ginkgo' 'vendor/github.com/onsi/ginkgo/ginkgo'
	os::util::ensure::built_binary_exists 'extended.test' 'test/extended/extended.test'
	os::util::ensure::built_binary_exists 'oadm'
	os::util::ensure::built_binary_exists 'oc'
	os::util::ensure::built_binary_exists 'junitmerge'

	# ensure proper relative directories are set
	export KUBE_REPO_ROOT="${OS_ROOT}/vendor/k8s.io/kubernetes"

	os::util::environment::setup_time_vars

	# Allow setting $JUNIT_REPORT to toggle output behavior
	if [[ -n "${JUNIT_REPORT:-}" ]]; then
		export JUNIT_REPORT_OUTPUT="${LOG_DIR}/raw_test_output.log"
		# the Ginkgo tests also generate jUnit but expect different envars
		export TEST_REPORT_DIR="${ARTIFACT_DIR}"
	fi

	function cleanup() {
		return_code=$?
		os::cleanup::all "${return_code}"
		exit "${return_code}"
	}
	trap "cleanup" EXIT

	if [[ -n "${TEST_ONLY-}" ]]; then
		os::log::info "Running tests against existing cluster..."
		return 0
	fi

	os::util::ensure::built_binary_exists 'openshift'

	os::util::environment::use_sudo
	os::cleanup::tmpdir
	os::util::environment::setup_all_server_vars
	os::util::ensure::iptables_privileges_exist

	os::log::info "Starting server"

	os::util::environment::setup_images_vars

	local sudo=${USE_SUDO:+sudo}

	# If the current system has the XFS volume dir mount point we configure
	# in the test images, assume to use it which will allow the local storage
	# quota tests to pass.
	LOCAL_STORAGE_QUOTA=""
	if [[ -d "/mnt/openshift-xfs-vol-dir" ]] && ${sudo} lvs | grep -q "xfs"; then
		LOCAL_STORAGE_QUOTA="1"
		export VOLUME_DIR="/mnt/openshift-xfs-vol-dir"
	else
		os::log::warning "/mnt/openshift-xfs-vol-dir does not exist, local storage quota tests may fail."
	fi

	os::log::system::start

	if [[ -n "${SHOW_ALL:-}" ]]; then
		SKIP_NODE=1
	fi

	# when selinux is enforcing, the volume dir selinux label needs to be
	# svirt_sandbox_file_t
	#
	# TODO: fix the selinux policy to either allow openshift_var_lib_dir_t
	# or to default the volume dir to svirt_sandbox_file_t.
	if selinuxenabled; then
		${sudo} chcon -t svirt_sandbox_file_t ${VOLUME_DIR}
	fi
	CONFIG_VERSION=""
	if [[ -n "${API_SERVER_VERSION:-}" ]]; then
		CONFIG_VERSION="${API_SERVER_VERSION}"
	elif [[ -n "${CONTROLLER_VERSION:-}" ]]; then
		CONFIG_VERSION="${CONTROLLER_VERSION}"
	fi
	os::start::configure_server "${CONFIG_VERSION}"
	#turn on audit logging for extended tests ... mimic what is done in os::start::configure_server, but don't
	# put change there - only want this for extended tests
	os::log::info "Turn on audit logging"
	cp "${SERVER_CONFIG_DIR}/master/master-config.yaml" "${SERVER_CONFIG_DIR}/master/master-config.orig2.yaml"
	openshift ex config patch "${SERVER_CONFIG_DIR}/master/master-config.orig2.yaml" --patch="{\"auditConfig\": {\"enabled\": true}}"  > "${SERVER_CONFIG_DIR}/master/master-config.yaml"

	cp "${SERVER_CONFIG_DIR}/master/master-config.yaml" "${SERVER_CONFIG_DIR}/master/master-config.orig2.yaml"
	openshift ex config patch "${SERVER_CONFIG_DIR}/master/master-config.orig2.yaml" --patch="{\"templateServiceBrokerConfig\": {\"templateNamespaces\": [\"openshift\"]}}"  > "${SERVER_CONFIG_DIR}/master/master-config.yaml"

	# If the XFS volume dir mount point exists enable local storage quota in node-config.yaml so these tests can pass:
	if [[ -n "${LOCAL_STORAGE_QUOTA}" ]]; then
		# The ec2 images usually have ~5Gi of space defined for the xfs vol for the registry; want to give /registry a good chunk of that
		# to store the images created when the extended tests run
		cp "${NODE_CONFIG_DIR}/node-config.yaml" "${NODE_CONFIG_DIR}/node-config.orig2.yaml"
		openshift ex config patch "${NODE_CONFIG_DIR}/node-config.orig2.yaml" --patch='{"volumeConfig":{"localQuota":{"perFSGroup":"4480Mi"}}}' > "${NODE_CONFIG_DIR}/node-config.yaml"
	fi
	os::log::info "Using VOLUME_DIR=${VOLUME_DIR}"

	# This is a bit hacky, but set the pod gc threshold appropriately for the garbage_collector test
	# and enable-hostpath-provisioner for StatefulSet tests
	cp "${SERVER_CONFIG_DIR}/master/master-config.yaml" "${SERVER_CONFIG_DIR}/master/master-config.orig3.yaml"
	openshift ex config patch "${SERVER_CONFIG_DIR}/master/master-config.orig3.yaml" --patch='{"kubernetesMasterConfig":{"controllerArguments":{"terminated-pod-gc-threshold":["100"], "enable-hostpath-provisioner":["true"]}}}' > "${SERVER_CONFIG_DIR}/master/master-config.yaml"

	os::start::server "${API_SERVER_VERSION:-}" "${CONTROLLER_VERSION:-}" "${SKIP_NODE:-}"

	export KUBECONFIG="${ADMIN_KUBECONFIG}"

	os::start::registry
	if [[ -z "${SKIP_NODE:-}" ]]; then
		oc rollout status dc/docker-registry
	fi
	DROP_SYN_DURING_RESTART=true CREATE_ROUTER_CERT=true os::start::router

	os::log::info "Creating image streams"
	oc create -n openshift -f "${OS_ROOT}/examples/image-streams/image-streams-centos7.json" --config="${ADMIN_KUBECONFIG}"

	os::log::info "Creating quickstart templates"
	oc create -n openshift -f "${OS_ROOT}/examples/quickstarts" --config="${ADMIN_KUBECONFIG}"
}

# Run extended tests or print out a list of tests that need to be run
# Input:
# - FOCUS - the extended test focus
# - SKIP - the tests to skip
# - TEST_EXTENDED_SKIP - a global filter that allows additional tests to be omitted, will
#     be joined with SKIP
# - SHOW_ALL - if set, then only print out tests to be run
# - TEST_PARALLEL - if set, run the tests in parallel with the specified number of nodes
# - Arguments - arguments to pass to ginkgo
function os::test::extended::run () {
	local listArgs=()
	local runArgs=()

	if [[ -n "${FOCUS-}" ]]; then
		listArgs+=("--ginkgo.focus=${FOCUS}")
		runArgs+=("-focus=${FOCUS}")
	fi

	local skip="${SKIP-}"
	# Allow additional skips to be provided on the command line
	if [[ -n "${TEST_EXTENDED_SKIP-}" ]]; then
		if [[ -n "${skip}" ]]; then
			skip="${skip}|${TEST_EXTENDED_SKIP}"
		else
			skip="${TEST_EXTENDED_SKIP}"
		fi
	fi
	if [[ -n "${skip}" ]]; then
		listArgs+=("--ginkgo.skip=${skip}")
		runArgs+=("-skip=${skip}")
	fi

	if [[ -n "${TEST_PARALLEL-}" ]]; then
		runArgs+=("-p" "-nodes=${TEST_PARALLEL}")
	fi

	if [[ -n "${SHOW_ALL-}" ]]; then
		PRINT_TESTS=1
		os::test::extended::test_list "${listArgs[@]:+"${listArgs[@]}"}"
		return
	fi

	os::test::extended::test_list "${listArgs[@]:+"${listArgs[@]}"}"

	if [[ "${TEST_COUNT}" -eq 0 ]]; then
		os::log::warning "No tests were selected"
		return
	fi

	ginkgo -v -noColor "${runArgs[@]:+"${runArgs[@]}"}" "$( os::util::find::built_binary extended.test )" "$@"
}

# Create a list of extended tests to be run with the given arguments
# Input:
# - Arguments to pass to ginkgo
# - SKIP_ONLY - If set, only selects tests to be skipped
# - PRINT_TESTS - If set, print the list of tests
# Output:
# - TEST_COUNT - the number of tests selected by the arguments
function os::test::extended::test_list () {
	local full_test_list=()
	local selected_tests=()

	while IFS= read -r; do
		full_test_list+=( "${REPLY}" )
	done < <(TEST_OUTPUT_QUIET=true extended.test "$@" --ginkgo.dryRun --ginkgo.noColor )
	if [[ "${REPLY}" ]]; then lines+=( "$REPLY" ); fi

	for test in "${full_test_list[@]}"; do
		if [[ -n "${SKIP_ONLY:-}" ]]; then
			if grep -q "35mskip" <<< "${test}"; then
				selected_tests+=( "${test}" )
			fi
		else
			if grep -q "1mok" <<< "${test}"; then
				selected_tests+=( "${test}" )
			fi
		fi
	done
	if [[ -n "${PRINT_TESTS:-}" ]]; then
		if [[ ${#selected_tests[@]} -eq 0 ]]; then
			os::log::warning "No tests were selected"
		else
			printf '%s\n' "${selected_tests[@]}" | sort
		fi
	fi
	export TEST_COUNT=${#selected_tests[@]}
}
readonly -f os::test::extended::test_list

# Merge all of the JUnit output files in the TEST_REPORT_DIR into a single file.
# This works around a gap in Jenkins JUnit reporter output that double counts skipped
# files until https://github.com/jenkinsci/junit-plugin/pull/54 is merged.
function os::test::extended::merge_junit () {
	if [[ -z "${JUNIT_REPORT:-}" ]]; then
		return
	fi
	local output
	output="$( mktemp )"
	"$( os::util::find::built_binary junitmerge )" "${TEST_REPORT_DIR}"/*.xml > "${output}"
	rm "${TEST_REPORT_DIR}"/*.xml
	mv "${output}" "${TEST_REPORT_DIR}/junit.xml"
}
readonly -f os::test::extended::merge_junit