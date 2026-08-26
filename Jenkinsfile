pipeline {
  agent any

  options {
    timestamps()
    buildDiscarder(logRotator(numToKeepStr: '20'))
  }

  environment {
    TF_VAR_localstack_endpoint = 'http://localstack-main:4566'
    AWS_ACCESS_KEY_ID          = 'test'
    AWS_SECRET_ACCESS_KEY      = 'test'
    AWS_DEFAULT_REGION         = 'us-east-1'
    AWS_ENDPOINT_URL_S3        = 'http://localstack-main:4566'
  }

  stages {

    // Stale outputs from a previous build are not source code.
    // Terraform embeds a full config snapshot inside tfplan, which
    // scanners will happily read as if it were the current code.
    stage('Prepare') {
      steps {
        sh 'rm -f tfplan gitleaks-report.json checkov-report.xml'
      }
    }

    stage('Secret Scan') {
      steps {
        sh '''
          gitleaks dir . \
            --no-banner \
            --report-format json \
            --report-path gitleaks-report.json \
            --exit-code 1
        '''
      }
    }

    stage('IaC Policy Scan') {
      steps {
        sh '''
          checkov -d . \
            --framework terraform \
            --compact \
            --output cli \
            --output junitxml \
            --output-file-path console,checkov-report.xml
        '''
      }
    }

    stage('IaC Misconfig Scan') {
      steps {
        sh '''
          trivy config . \
            --format table \
            --exit-code 1 \
            --severity HIGH,CRITICAL \
            --skip-files "tfplan" \
            --skip-files "**/tfplan"
        '''
      }
    }

    stage('Init')     { steps { sh 'terraform init -input=false' } }
    stage('Validate') { steps { sh 'terraform validate' } }

    stage('Plan') {
      steps {
        script {
          def rc = sh(
            returnStatus: true,
            script: 'terraform plan -input=false -detailed-exitcode -out=tfplan'
          )
          if (rc == 0) {
            env.TF_HAS_CHANGES = 'false'
            echo 'No infrastructure changes. Approve and Apply will be skipped.'
          } else if (rc == 2) {
            env.TF_HAS_CHANGES = 'true'
            echo 'Plan contains changes. Approval required.'
          } else {
            error("terraform plan failed with exit code ${rc}")
          }
        }
      }
    }

    stage('Approve') {
      when {
        beforeInput true
        environment name: 'TF_HAS_CHANGES', value: 'true'
      }
      options { timeout(time: 30, unit: 'MINUTES') }
      input {
        message 'Apply this plan to LocalStack?'
        ok 'Apply'
      }
      steps { echo 'Approved by operator.' }
    }

    stage('Apply') {
      when { environment name: 'TF_HAS_CHANGES', value: 'true' }
      steps { sh 'terraform apply -input=false tfplan' }
    }

    stage('Verify') {
      steps {
        sh '''
          aws --endpoint-url=$TF_VAR_localstack_endpoint s3 ls
          aws --endpoint-url=$TF_VAR_localstack_endpoint dynamodb list-tables
          aws --endpoint-url=$TF_VAR_localstack_endpoint sqs list-queues
          aws --endpoint-url=$TF_VAR_localstack_endpoint kms list-aliases
        '''
      }
    }
  }

  post {
    always {
      archiveArtifacts artifacts: 'tfplan, gitleaks-report.json, checkov-report.xml',
                       allowEmptyArchive: true
      junit testResults: 'checkov-report.xml', allowEmptyResults: true
    }
  }
}
