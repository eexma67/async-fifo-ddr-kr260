pipeline {
    agent any

    parameters {
        choice(name: 'SIM_TOOL', choices: ['xsim', 'questa'], description: 'Simulation tool')
        choice(name: 'BUILD_TYPE', choices: ['full', 'sim_only', 'hw_only'], description: 'Pipeline scope')
        string(name: 'FIFO_DEPTH', defaultValue: '1024', description: 'Async FIFO depth (power of 2)')
        string(name: 'DATA_WIDTH', defaultValue: '64', description: 'Data bus width in bits')
        string(name: 'DDR_BURST_LEN', defaultValue: '256', description: 'DDR burst length (beats)')
        booleanParam(name: 'RUN_HIL', defaultValue: true, description: 'Run hardware-in-the-loop tests')
        string(name: 'KR260_TARGET', defaultValue: '192.168.0.58', description: 'KR260 board IP')
    }

    environment {
        VIVADO_HOME     = '/opt/Xilinx/Vivado/2024.1'
        PART            = 'xck26-sfvc784-2LV-c'
        BOARD           = 'xilinx.com:kr260_som:part0:1.0'
        PROJECT_NAME    = 'async_fifo_ddr'
        WORK_DIR        = "${WORKSPACE}/build"
        SIM_DIR         = "${WORKSPACE}/sim"
        RESULTS_DIR     = "${WORKSPACE}/results"
        FIFO_DEPTH      = "${params.FIFO_DEPTH}"
        DATA_WIDTH      = "${params.DATA_WIDTH}"
        DDR_BURST_LEN   = "${params.DDR_BURST_LEN}"
    }

    options {
        timestamps()
        timeout(time: 4, unit: 'HOURS')
        buildDiscarder(logRotator(numToKeepStr: '20'))
    }

    stages {
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

        stage('RTL Lint') {
            steps {
                sh '''
                    echo "=== Verilator Lint ==="
                    verilator --lint-only -Wall -Wno-fatal \
                        -DFIFO_DEPTH=${FIFO_DEPTH} \
                        -DDATA_WIDTH=${DATA_WIDTH} \
                        -DDDR_BURST_LEN=${DDR_BURST_LEN} \
                        rtl/async_fifo.sv \
                        rtl/axi_dma_controller.sv \
                        rtl/async_fifo_ddr_top.sv \
                        --top-module async_fifo_ddr_top \
                        2>&1 | tee ${RESULTS_DIR}/lint_report.log || true
                '''
            }
            post {
                always {
                    archiveArtifacts artifacts: 'results/lint_report.log', allowEmptyArchive: true
                }
            }
        }

        stage('UVM Simulation') {
            when {
                expression { return params.BUILD_TYPE != 'hw_only' }
            }
            stages {
                stage('Compile UVM TB') {
                    steps {
                        sh '''
                            source ${VIVADO_HOME}/settings64.sh
                            cd ${SIM_DIR}

                            echo "=== Compiling RTL + UVM Testbench ==="
                            xvlog -sv \
                                -d FIFO_DEPTH=${FIFO_DEPTH} \
                                -d DATA_WIDTH=${DATA_WIDTH} \
                                -d DDR_BURST_LEN=${DDR_BURST_LEN} \
                                -L uvm \
                                ${WORKSPACE}/rtl/async_fifo.sv \
                                ${WORKSPACE}/rtl/axi_dma_controller.sv \
                                ${WORKSPACE}/rtl/async_fifo_ddr_top.sv \
                                ${WORKSPACE}/tb/uvm/fifo_ddr_interfaces.sv \
                                ${WORKSPACE}/tb/uvm/axi4_mem_slave.sv \
                                ${WORKSPACE}/tb/uvm/env/fifo_ddr_env_pkg.sv \
                                ${WORKSPACE}/tb/uvm/sequences/fifo_ddr_sequences.sv \
                                ${WORKSPACE}/tb/uvm/tests/fifo_ddr_tests.sv \
                                ${WORKSPACE}/tb/uvm/tb_top.sv \
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
                                    -runall \
                                    2>&1 || true

                                if grep -q "UVM_FATAL\\|UVM_ERROR" ${RESULTS_DIR}/${TEST}.log 2>/dev/null; then
                                    echo "FAIL: ${TEST}" >> ${RESULTS_DIR}/test_summary.txt
                                else
                                    echo "PASS: ${TEST}" >> ${RESULTS_DIR}/test_summary.txt
                                fi
                            done

                            echo "=== Test Summary ==="
                            cat ${RESULTS_DIR}/test_summary.txt || echo "No test summary generated"
                        '''
                    }
                }
            }
            post {
                always {
                    archiveArtifacts artifacts: 'results/**/*.log', allowEmptyArchive: true
                    sh '''
                        python3 ${WORKSPACE}/scripts/uvm_log_to_junit.py \
                            ${RESULTS_DIR}/test_summary.txt \
                            ${RESULTS_DIR}/uvm_results.xml || true
                    '''
                    junit allowEmptyResults: true, testResults: 'results/uvm_results.xml'
                }
            }
        }

        stage('Synthesis & Implementation') {
            when {
                expression { return params.BUILD_TYPE != 'sim_only' }
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
                }
            }
        }

        stage('Hardware-in-the-Loop') {
            when {
                allOf {
                    expression { return params.RUN_HIL == true }
                    expression { return params.BUILD_TYPE != 'sim_only' }
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
                                -log ${RESULTS_DIR}/program.log || true
                        '''
                    }
                }
                stage('Run HIL Tests') {
                    steps {
                        sh '''
                            echo "=== Hardware-in-the-Loop Tests ==="
                            python3 ${WORKSPACE}/scripts/hil_test_runner.py \
                                --target ${KR260_TARGET} \
                                --user ubuntu \
                                --fifo-depth ${FIFO_DEPTH} \
                                --data-width ${DATA_WIDTH} \
                                --burst-len ${DDR_BURST_LEN} \
                                --output-dir ${RESULTS_DIR}/hil \
                                --tests all \
                                2>&1 | tee ${RESULTS_DIR}/hil_test.log || true
                        '''
                    }
                }
            }
            post {
                always {
                    archiveArtifacts artifacts: 'results/hil/**', allowEmptyArchive: true
                }
            }
        }
    }

    post {
        success {
            echo 'Pipeline PASSED - All stages completed successfully'
        }
        failure {
            echo 'Pipeline FAILED'
        }
        always {
            archiveArtifacts artifacts: 'results/**', allowEmptyArchive: true
        }
    }
}
