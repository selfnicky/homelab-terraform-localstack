pipeline {
  agent any

  environment {
    TF_VAR_localstack_endpoint = 'http://localstack-main:4566'
    AWS_ACCESS_KEY_ID          = 'test'
    AWS_SECRET_ACCESS_KEY      = 'test'
    AWS_DEFAULT_REGION         = 'us-east-1'
  }

  stages {
    stage('Init')     { steps { sh 'terraform init -input=false' } }
    stage('Validate') { steps { sh 'terraform validate' } }
    stage('Plan')     { steps { sh 'terraform plan -input=false -out=tfplan' } }

    stage('Approve') {
      steps { input message: 'Apply this plan to LocalStack?', ok: 'Apply' }
    }

    stage('Apply') { steps { sh 'terraform apply -input=false tfplan' } }

    stage('Verify') {
      steps {
        sh '''
          aws --endpoint-url=$TF_VAR_localstack_endpoint s3 ls
          aws --endpoint-url=$TF_VAR_localstack_endpoint dynamodb list-tables
          aws --endpoint-url=$TF_VAR_localstack_endpoint sqs list-queues
        '''
      }
    }
  }

  post {
    always { archiveArtifacts artifacts: 'tfplan', allowEmptyArchive: true }
  }
}
