/ ============================================================
// Jenkinsfile — Build → Test → Package → Push to Docker Hub
// ============================================================

pipeline {

    // ── Agent ────────────────────────────────────────────────
    // Any Jenkins node that has Docker installed.
    agent { label 'docker-agent' }

    // ── Tooling ───────────────────────────────────────────────
    tools {
        nodejs 'NodeJS-26.2.0'   // Must match the name in:
                             // Manage Jenkins → Global Tool Configuration
    }

    // ── Environment variables ─────────────────────────────────
    environment {
        // ── Application ──────────────────────────────────────
        APP_NAME     = 'cfo'
        APP_PORT     = '9000'

        // ── Docker Hub ───────────────────────────────────────
        // DOCKERHUB_CREDENTIALS must be a Username/Password secret
        // stored in Jenkins → Manage Credentials.
        // DOCKERHUB_USERNAME is the Docker Hub account or org name.
        DOCKERHUB_CREDENTIALS = 'dockerhub-credentials'
        DOCKERHUB_USERNAME    = 'auduj01'
        IMAGE_NAME            = "${DOCKERHUB_USERNAME}/${APP_NAME}"

        // Tag format: <branch>-<build number>-<short git sha>
        // This makes every image uniquely traceable back to a commit.
        IMAGE_TAG    = "${env.BRANCH_NAME}-${env.BUILD_NUMBER}-${env.GIT_COMMIT?.take(7) ?: 'unknown'}"
        IMAGE_FULL   = "${IMAGE_NAME}:${IMAGE_TAG}"
        IMAGE_LATEST = "${IMAGE_NAME}:latest"
    }

    // ── Options ───────────────────────────────────────────────
    options {
        buildDiscarder(logRotator(numToKeepStr: '10'))
        timestamps()
        timeout(time: 20, unit: 'MINUTES')
        disableConcurrentBuilds()
        ansiColor('xterm')
    }

    // ── Trigger ───────────────────────────────────────────────
    triggers {
        // Fallback polling — prefer a GitHub webhook in production.
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

                // Resolve short SHA after checkout so it is available
                // to every downstream stage via env.GIT_SHORT_SHA.
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

        // ── 2. Install Dependencies ───────────────────────────
        stage('Install') {
            steps {
                echo 'Installing dependencies…'
                // npm ci is used instead of npm install:
                //   - Reads package-lock.json exactly (reproducible)
                //   - Fails if lock file is out of date
                sh 'npm ci'
            }
        }

        // ── 3. Lint ───────────────────────────────────────────
        stage('Lint') {
            steps {
                echo 'Running linter…'
                sh 'npm run lint || true'
                // || true: lint warnings surface in logs without
                // failing the build — adjust to strict if preferred.
            }
        }

        // ── 4. Test ───────────────────────────────────────────
        stage('Test') {
            steps {
                echo 'Running unit tests…'
                sh 'npm test -- --coverage'
            }
            post {
                always {
                    // Publish JUnit results (requires JUnit plugin)
                    junit allowEmptyResults: true,
                          testResults: 'reports/junit/**/*.xml'

                    // Publish HTML coverage report (requires HTML Publisher plugin)
                    publishHTML([
                        allowMissing      : true,
                        alwaysLinkToLastBuild: true,
                        keepAll           : true,
                        reportDir         : 'coverage/lcov-report',
                        reportFiles       : 'index.html',
                        reportName        : 'Coverage Report'
                    ])
                }
            }
        }

        // ── 5. Package (Docker Build) ─────────────────────────
        stage('Package') {
            steps {
                echo "Building Docker image: ${IMAGE_FULL}"
                script {
                    // Pass build-time metadata as ARGs.
                    // The Dockerfile should declare:
                    //   ARG BUILD_DATE
                    //   ARG VCS_REF
                    // and set them as LABEL values for traceability.
                    dockerImage = docker.build(
                        IMAGE_FULL,
                        """--build-arg BUILD_DATE=${new Date().format("yyyy-MM-dd'T'HH:mm:ss'Z'")} \
                           --build-arg VCS_REF=${env.GIT_SHORT_SHA} \
                           ."""
                    )
                }
                echo "Image built successfully: ${IMAGE_FULL}"
            }
        }

        // ── 6. Transfer Artefact to Docker Hub ───────────────
        stage('Push to Docker Hub') {
            steps {
                echo "Pushing artefact to Docker Hub: ${IMAGE_FULL}"
                script {
                    // docker.withRegistry points the Docker CLI at Docker Hub
                    // and logs in using the stored Jenkins credential.
                    docker.withRegistry('https://index.docker.io/v1/', DOCKERHUB_CREDENTIALS) {

                        // Push the versioned tag (always)
                        dockerImage.push(IMAGE_TAG)
                        echo "Pushed versioned tag: ${IMAGE_FULL}"

                        // Push :latest only from the main/master branch
                        // to avoid feature branches polluting the latest tag.
                        if (env.BRANCH_NAME == 'main' || env.BRANCH_NAME == 'master') {
                            dockerImage.push('latest')
                            echo "Pushed latest tag: ${IMAGE_LATEST}"
                        } else {
                            echo "Skipped :latest push — branch is '${env.BRANCH_NAME}', not main/master"
                        }
                    }
                }
            }
        }

        // ── 7. Verify Push ────────────────────────────────────
        // Pulls the image back from Docker Hub to confirm the artefact
        // is accessible. Useful catch for registry permission issues.
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
            echo 'Archiving test reports and cleaning workspace…'
            archiveArtifacts artifacts: 'reports/**/*', allowEmptyArchive: true

            // Remove the local image from the agent to free disk space.
            // The image is already safely stored on Docker Hub at this point.
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
