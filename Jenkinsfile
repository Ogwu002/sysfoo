// ============================================================
// Jenkinsfile — Build → Test → Package → Push to Docker Hub
// Maven / Java project — cfo service
// ============================================================

pipeline {

    // ── Agent ────────────────────────────────────────────────
    agent { label 'docker-agent' }

    // ── Tooling ───────────────────────────────────────────────
    tools {
        // Names must match Manage Jenkins → Global Tool Configuration
        jdk   'JDK-21'          // Temurin 21 — matches eclipse-temurin:21 in Dockerfile
        maven 'Maven-3.9'       // Maven 3.9 — matches maven:3.9 in Dockerfile
    }

    // ── Environment variables ─────────────────────────────────
    environment {
        // ── Application ──────────────────────────────────────
        APP_NAME     = 'cfo'
        APP_PORT     = '9000'

        // ── Docker Hub ───────────────────────────────────────
        DOCKERHUB_CREDENTIALS = 'dockerhub-credentials'
        DOCKERHUB_USERNAME    = 'auduj01'
        IMAGE_NAME            = "${DOCKERHUB_USERNAME}/${APP_NAME}"

        // Tag: <branch>-<build number>-<short git sha>
        IMAGE_TAG    = "${env.BRANCH_NAME}-${env.BUILD_NUMBER}-${env.GIT_COMMIT?.take(7) ?: 'unknown'}"
        IMAGE_FULL   = "${IMAGE_NAME}:${IMAGE_TAG}"
        IMAGE_LATEST = "${IMAGE_NAME}:latest"

        // ── Maven ─────────────────────────────────────────────
        // Centralise Maven flags so they are easy to adjust.
        // -B        : batch mode (no colour, clean logs for Jenkins)
        // -T 1C     : one thread per CPU core (parallel module builds)
        MAVEN_OPTS   = '-Xmx512m'
        MVN_FLAGS    = '-B -T 1C'
    }

    // ── Options ───────────────────────────────────────────────
    options {
        buildDiscarder(logRotator(numToKeepStr: '10'))
        timestamps()
        timeout(time: 30, unit: 'MINUTES')   // Maven builds need more time than npm
        disableConcurrentBuilds()
        ansiColor('xterm')
    }

    // ── Trigger ───────────────────────────────────────────────
    triggers {
        pollSCM('H/5 * * * *')
    }

    // ════════════════════════════════════════════════════════
    // STAGES
    // ════════════════════════════════════════════════════════
    stages {

        // ── 1. Checkout ──────────────────────────────────────
        stage('Checkout') {
            steps {
                echo "Branch  : ${env.BRANCH_NAME}"
                echo "Build # : ${env.BUILD_NUMBER}"

                checkout scm

                script {
                    env.GIT_SHORT_SHA = sh(
                        script: 'git rev-parse --short HEAD',
                        returnStdout: true
                    ).trim()
                    env.GIT_AUTHOR = sh(
                        script: 'git log -1 --pretty=format:%an',
                        returnStdout: true
                    ).trim()
                }

                echo "Commit  : ${env.GIT_SHORT_SHA} by ${env.GIT_AUTHOR}"
            }
        }

        // ── 2. Build ──────────────────────────────────────────
        // Compiles the source and runs annotation processing.
        // Tests are skipped here — they run in their own stage
        // so failures are reported separately from compile errors.
        stage('Build') {
            steps {
                echo 'Compiling source with Maven…'
                sh "mvn ${MVN_FLAGS} compile -DskipTests"
            }
        }

        // ── 3. Test ───────────────────────────────────────────
        // Runs unit and integration tests and produces:
        //   - Surefire XML reports  → reports/junit/
        //   - JaCoCo coverage XML   → target/site/jacoco/
        stage('Test') {
            steps {
                echo 'Running tests…'
                sh "mvn ${MVN_FLAGS} test"
            }
            post {
                always {
                    // Publish Surefire JUnit XML results
                    junit allowEmptyResults: true,
                          testResults: 'target/surefire-reports/**/*.xml'

                    // Publish JaCoCo coverage (requires JaCoCo plugin)
                    jacoco(
                        execPattern       : 'target/jacoco.exec',
                        classPattern      : 'target/classes',
                        sourcePattern     : 'src/main/java',
                        exclusionPattern  : '**/dto/**, **/config/**',
                        minimumLineCoverage: '60'   // fail if coverage drops below 60%
                    )
                }
            }
        }

        // ── 4. Package ────────────────────────────────────────
        // Runs mvn package to produce the fat JAR, then hands it
        // to docker.build which passes the BUILD_DATE and VCS_REF
        // build-args declared in the Dockerfile.
        stage('Package') {
            steps {
                echo 'Packaging JAR with Maven…'
                // verify runs the full lifecycle (compile → test → package → verify)
                // and checks integration tests if configured.
                // -DskipTests because the Test stage already ran them.
                sh "mvn ${MVN_FLAGS} package -DskipTests"

                echo "Building Docker image: ${IMAGE_FULL}"
                script {
                    dockerImage = docker.build(
                        IMAGE_FULL,
                        "--build-arg BUILD_DATE=${new Date().format("yyyy-MM-dd'T'HH:mm:ss'Z'")} " +
                        "--build-arg VCS_REF=${env.GIT_SHORT_SHA} " +
                        "."
                    )
                }
                echo "Docker image built: ${IMAGE_FULL}"
            }
            post {
                success {
                    // Archive the JAR as a Jenkins build artefact
                    archiveArtifacts artifacts: 'target/*.jar', fingerprint: true
                }
            }
        }

        // ── 5. Push to Docker Hub ─────────────────────────────
        stage('Push to Docker Hub') {
            steps {
                echo "Pushing artefact to Docker Hub: ${IMAGE_FULL}"
                script {
                    docker.withRegistry('https://index.docker.io/v1/', DOCKERHUB_CREDENTIALS) {

                        // Always push the versioned tag
                        dockerImage.push(IMAGE_TAG)
                        echo "Pushed versioned tag : ${IMAGE_FULL}"

                        // Push :latest only from main/master
                        if (env.BRANCH_NAME == 'main' || env.BRANCH_NAME == 'master') {
                            dockerImage.push('latest')
                            echo "Pushed latest tag    : ${IMAGE_LATEST}"
                        } else {
                            echo "Skipped :latest — branch is '${env.BRANCH_NAME}'"
                        }
                    }
                }
            }
        }

        // ── 6. Verify ─────────────────────────────────────────
        // Pulls the image back from Docker Hub to confirm the
        // artefact is publicly accessible and the push succeeded.
        stage('Verify') {
            steps {
                echo "Verifying image is accessible on Docker Hub…"
                script {
                    docker.withRegistry('https://index.docker.io/v1/', DOCKERHUB_CREDENTIALS) {
                        docker.image(IMAGE_FULL).pull()
                    }
                }
                echo "Verification passed — ${IMAGE_FULL} is on Docker Hub"
            }
        }

    }
    // ════════════════════════════════════════════════════════
    // END STAGES
    // ════════════════════════════════════════════════════════

    // ── Post-pipeline actions ─────────────────────────────────
    post {

        always {
            echo 'Cleaning workspace…'

            // Remove the local Docker image to free agent disk space.
            // The image is already safely on Docker Hub at this point.
            sh "docker rmi ${IMAGE_FULL} || true"
            sh "docker rmi ${IMAGE_LATEST} || true"

            cleanWs()
        }

        success {
            echo """
            ========================================
            BUILD SUCCEEDED
            Image : ${IMAGE_FULL}
            Hub   : https://hub.docker.com/r/${IMAGE_NAME}
            ========================================
            """
        }

        failure {
            echo """
            ========================================
            BUILD FAILED at stage: ${env.STAGE_NAME}
            Branch : ${env.BRANCH_NAME}
            Build  : #${env.BUILD_NUMBER}
            ========================================
            """
        }

    }
}
