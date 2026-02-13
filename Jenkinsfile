// =============================================================================
// Jenkinsfile: CI/CD Pipeline for Async-FIFO <-> DDR Data Transfer (KR260)
// Author: Mohammed (Radio Cosmology Group, Cambridge)
// =============================================================================
// Pipeline Stages:
//   1. Checkout & Environment Setup
//   2. RTL Lint (Verilator)
//   3. UVM Simulation (Vivado xsim / Questa)
//   4. Vivado Synthesis & Implementation
//   5. Bitstream Generation
//   6. Hardware-in-the-Loop Test (KR260)
//   7. Report & Archive
// =============================================================================

pipeline {
    agent {
        label 'fpga-build'  // Node with Vivado + KR260 JTAG access
    }

    parameters {
        choice(name: 'SIM_TOOL', choices: ['xsim', 'questa'], description: 'Simulation tool')
        choice(name: 'BUILD_TYPE', choices: ['full', 'sim_only', 'hw_only'], description: 'Pipeline scope')
        string(name: 'FIFO_DEPTH', defaultValue: '1024', description: 'Async FIFO depth (power of 2)')
        string(name: 'DATA_WIDTH', defaultValue: '64', description: 'Data bus width in bits')
        string(name: 'DDR_BURST_LEN', defaultValue: '256', description: 'DDR burst length (beats)')
        booleanParam(name: 'RUN_HIL', defaultValue: true, description: 'Run hardware-in-the-loop tests')
        string(name: 'KR260_TARGET', defaultValue: '192.168.1.100', description: 'KR260 board IP (for remote JTAG)')
    }

    environment {
        VIVADO_HOME     = '/tools/Xilinx/Vivado/2024.1'
        VIVADO_BIN      = "${VIVADO_HOME}/bin/vivado"
        XSIM_BIN        = "${VIVADO_HOME}/bin/xsim"
        VLOG_BIN        = "${VIVADO_HOME}/bin/xvlog"
        VLIB_BIN        = "${VIVADO_HOME}/bin/xvhdl"
        HW_SERVER       = "${VIVADO_HOME}/bin/hw_server"
        PART            = "xck26-sfvc784-2LV-c"  // KR260 SOM Kria K26
        BOARD           = "xilinx.com:kr260_som:part0:1.0"
        PROJECT_NAME    = "async_fifo_ddr"
        WORK_DIR        = "${WORKSPACE}/build"
        SIM_DIR         = "${WORKSPACE}/sim"
        RESULTS_DIR     = "${WORKSPACE}/results"
        UVM_HOME        = "${VIVADO_HOME}/data/system_verilog/uvm"
        // Parametrise DUT
        FIFO_DEPTH      = "${params.FIFO_DEPTH}"
        DATA_WIDTH      = "${params.DATA_WIDTH}"
        DDR_BURST_LEN   = "${params.DDR_BURST_LEN}"
    }

    options {
        timestamps()
        timeout(time: 4, unit: 'HOURS')
        buildDiscarder(logRotator(numToKeepStr: '20'))
        ansiColor('xterm')
    }

    stages {
        // =====================================================================
        // Stage 1: Checkout & Environment
        // =====================================================================
        stage('Checkout & Setup') {
            steps {
                checkout scm
                sh '''
                    echo "=== Environment ==="
                    source ${VIVADO_HOME}/settings64.sh
                    vivado -version
                    echo "Target Part: ${PART}"
                    echo "FIFO Depth:  ${FIFO_DEPTH}"
                    echo "Data Width:  ${DATA_WIDTH}"
                    echo "DDR Burst:   ${DDR_BURST_LEN}"
                    mkdir -p ${WORK_DIR} ${SIM_DIR} ${RESULTS_DIR}
                '''
            }
        }

        // =====================================================================
        // Stage 2: RTL Lint
        // =====================================================================
        stage('RTL Lint') {
            steps {
                sh '''
                    echo "=== Verilator Lint ==="
                    verilator --lint-only -Wall \
                        +define+FIFO_DEPTH=${FIFO_DEPTH} \
                        +define+DATA_WIDTH=${DATA_WIDTH} \
                        +define+DDR_BURST_LEN=${DDR_BURST_LEN} \
                        -f rtl/filelist.f \
                        --top-module async_fifo_ddr_top \
                        2>&1 | tee ${RESULTS_DIR}/lint_report.log
                '''
            }
            post {
                always {
                    archiveArtifacts artifacts: 'results/lint_report.log', allowEmptyArchive: true
                }
            }
        }

        // =====================================================================
        // Stage 3: UVM Simulation
        // =====================================================================
        stage('UVM Simulation') {
            when {
                expression { params.BUILD_TYPE != 'hw_only' }
            }
            stages {
                stage('Compile UVM TB') {
                    steps {
                        sh '''
                            source ${VIVADO_HOME}/settings64.sh
                            cd ${SIM_DIR}

                            echo "=== Compiling RTL + UVM Testbench ==="
                            xvlog -sv \
                                +define+FIFO_DEPTH=${FIFO_DEPTH} \
                                +define+DATA_WIDTH=${DATA_WIDTH} \
                                +define+DDR_BURST_LEN=${DDR_BURST_LEN} \
                                -L uvm \
                                -f ${WORKSPACE}/rtl/filelist.f \
                                -f ${WORKSPACE}/tb/uvm/tb_filelist.f \
                                --log compile.log 2>&1
                        '''
                    }
                }
                stage('Elaborate') {
                    steps {
                        sh '''
                            source ${VIVADO_HOME}/settings64.sh
                            cd ${SIM_DIR}

                            xelab tb_top -relax -s sim_snapshot \
                                -L uvm \
                                -timescale 1ns/1ps \
                                --log elaborate.log 2>&1
                        '''
                    }
                }
                stage('Run UVM Tests') {
                    steps {
                        sh '''
                            source ${VIVADO_HOME}/settings64.sh
                            cd ${SIM_DIR}

                            # Run test suite
                            for TEST in \
                                fifo_ddr_basic_write_read_test \
                                fifo_ddr_burst_transfer_test \
                                fifo_ddr_clock_domain_stress_test \
                                fifo_ddr_backpressure_test \
                                fifo_ddr_overflow_underflow_test \
                                fifo_ddr_random_traffic_test \
                                fifo_ddr_reset_recovery_test; do

                                echo "=== Running: ${TEST} ==="
                                xsim sim_snapshot \
                                    -testplusarg "UVM_TESTNAME=${TEST}" \
                                    -testplusarg "UVM_VERBOSITY=UVM_MEDIUM" \
                                    --log ${RESULTS_DIR}/${TEST}.log \
                                    --tclbatch ${WORKSPACE}/scripts/run_sim.tcl \
                                    2>&1

                                # Check for UVM_FATAL or UVM_ERROR
                                if grep -q "UVM_FATAL\\|UVM_ERROR" ${RESULTS_DIR}/${TEST}.log; then
                                    echo "FAIL: ${TEST}" >> ${RESULTS_DIR}/test_summary.txt
                                else
                                    echo "PASS: ${TEST}" >> ${RESULTS_DIR}/test_summary.txt
                                fi
                            done

                            echo "=== Test Summary ==="
                            cat ${RESULTS_DIR}/test_summary.txt

                            # Fail build if any test failed
                            if grep -q "FAIL" ${RESULTS_DIR}/test_summary.txt; then
                                echo "ERROR: One or more UVM tests failed!"
                                exit 1
                            fi
                        '''
                    }
                }
                stage('Coverage Merge') {
                    steps {
                        sh '''
                            source ${VIVADO_HOME}/settings64.sh
                            cd ${SIM_DIR}

                            echo "=== Merging Coverage ==="
                            # Merge functional coverage databases
                            xcrg -dir ${SIM_DIR}/xsim.covdb \
                                 -report_dir ${RESULTS_DIR}/coverage \
                                 -report_format html \
                                 2>&1 | tee ${RESULTS_DIR}/coverage_merge.log
                        '''
                    }
                }
            }
            post {
                always {
                    archiveArtifacts artifacts: 'results/**/*.log, results/coverage/**', allowEmptyArchive: true
                    // Publish UVM results as JUnit (requires log parser)
                    sh '''
                        python3 ${WORKSPACE}/scripts/uvm_log_to_junit.py \
                            ${RESULTS_DIR}/test_summary.txt \
                            ${RESULTS_DIR}/uvm_results.xml
                    '''
                    junit 'results/uvm_results.xml'
                }
            }
        }

        // =====================================================================
        // Stage 4: Vivado Synthesis & Implementation
        // =====================================================================
        stage('Synthesis & Implementation') {
            when {
                expression { params.BUILD_TYPE != 'sim_only' }
            }
            steps {
                sh '''
                    source ${VIVADO_HOME}/settings64.sh
                    cd ${WORK_DIR}

                    echo "=== Running Vivado Build ==="
                    vivado -mode batch \
                        -source ${WORKSPACE}/scripts/build_bitstream.tcl \
                        -tclargs \
                            ${PART} \
                            ${WORKSPACE}/rtl \
                            ${WORKSPACE}/constraints \
                            ${PROJECT_NAME} \
                            ${FIFO_DEPTH} \
                            ${DATA_WIDTH} \
                            ${DDR_BURST_LEN} \
                        -log ${RESULTS_DIR}/vivado_build.log \
                        -journal ${RESULTS_DIR}/vivado_build.jou
                '''
            }
            post {
                always {
                    archiveArtifacts artifacts: 'results/vivado_build.log', allowEmptyArchive: true
                    // Parse timing summary
                    sh '''
                        python3 ${WORKSPACE}/scripts/parse_timing.py \
                            ${WORK_DIR}/${PROJECT_NAME}/${PROJECT_NAME}.runs/impl_1/timing_summary_routed.rpt \
                            ${RESULTS_DIR}/timing_results.json
                    '''
                }
                success {
                    archiveArtifacts artifacts: "build/${PROJECT_NAME}/${PROJECT_NAME}.runs/impl_1/*.bit", allowEmptyArchive: true
                }
            }
        }

        // =====================================================================
        // Stage 5: Hardware-in-the-Loop Test (KR260)
        // =====================================================================
        stage('Hardware-in-the-Loop') {
            when {
                allOf {
                    expression { params.RUN_HIL == true }
                    expression { params.BUILD_TYPE != 'sim_only' }
                }
            }
            stages {
                stage('Program KR260') {
                    steps {
                        sh '''
                            source ${VIVADO_HOME}/settings64.sh

                            echo "=== Programming KR260 ==="
                            vivado -mode batch \
                                -source ${WORKSPACE}/scripts/program_kr260.tcl \
                                -tclargs \
                                    ${WORK_DIR}/${PROJECT_NAME}/${PROJECT_NAME}.runs/impl_1/${PROJECT_NAME}_top.bit \
                                    ${KR260_TARGET} \
                                -log ${RESULTS_DIR}/program.log
                        '''
                    }
                }
                stage('Run HIL Tests') {
                    steps {
                        sh '''
                            echo "=== Hardware-in-the-Loop Data Transfer Tests ==="

                            python3 ${WORKSPACE}/scripts/hil_test_runner.py \
                                --target ${KR260_TARGET} \
                                --fifo-depth ${FIFO_DEPTH} \
                                --data-width ${DATA_WIDTH} \
                                --burst-len ${DDR_BURST_LEN} \
                                --output-dir ${RESULTS_DIR}/hil \
                                --tests all \
                                2>&1 | tee ${RESULTS_DIR}/hil_test.log

                            # Convert HIL results to JUnit
                            python3 ${WORKSPACE}/scripts/hil_to_junit.py \
                                ${RESULTS_DIR}/hil/results.json \
                                ${RESULTS_DIR}/hil_results.xml
                        '''
                    }
                }
            }
            post {
                always {
                    archiveArtifacts artifacts: 'results/hil/**', allowEmptyArchive: true
                    junit 'results/hil_results.xml'
                }
            }
        }

        // =====================================================================
        // Stage 6: Reports & Notifications
        // =====================================================================
        stage('Generate Reports') {
            steps {
                sh '''
                    python3 ${WORKSPACE}/scripts/generate_report.py \
                        --results-dir ${RESULTS_DIR} \
                        --output ${RESULTS_DIR}/build_report.html
                '''
            }
            post {
                always {
                    publishHTML(target: [
                        allowMissing: true,
                        alwaysLinkToLastBuild: true,
                        keepAll: true,
                        reportDir: 'results',
                        reportFiles: 'build_report.html',
                        reportName: 'Build Report'
                    ])
                }
            }
        }
    }

    post {
        success {
            echo "Pipeline PASSED - All stages completed successfully"
            // Optional: email / Slack notification
            // slackSend channel: '#fpga-ci', color: 'good', message: "KR260 Build #${BUILD_NUMBER} PASSED"
        }
        failure {
            echo "Pipeline FAILED"
            // slackSend channel: '#fpga-ci', color: 'danger', message: "KR260 Build #${BUILD_NUMBER} FAILED"
        }
        always {
            archiveArtifacts artifacts: 'results/**', allowEmptyArchive: true
            cleanWs()
        }
    }
}
