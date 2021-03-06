require 'spec_helper'

describe 'Jobs' do
  let!(:jobs) {[
    FactoryGirl.create(:test, :number => '3.1', :queue => 'builds.common'),
    FactoryGirl.create(:test, :number => '3.2', :queue => 'builds.common')
  ]}
  let(:job) { jobs.first }
  let(:headers) { { 'HTTP_ACCEPT' => 'application/vnd.travis-ci.2+json' } }

  it '/jobs?queue=builds.common' do
    response = get '/jobs', { queue: 'builds.common' }, headers
    response.should deliver_json_for(Job.queued('builds.common'), version: 'v2')
  end

  it '/jobs/:id' do
    response = get "/jobs/#{job.id}", {}, headers
    response.should deliver_json_for(job, version: 'v2')
  end

  context 'GET /jobs/:job_id/log.txt' do
    it 'returns log for a job' do
      job.log.update_attributes!(content: 'the log')
      response = get "/jobs/#{job.id}/log.txt", {}, headers
      response.should deliver_as_txt('the log', version: 'v2')
    end

    context 'when log is archived' do
      it 'redirects to archive' do
        job.log.update_attributes!(content: 'the log', archived_at: Time.now, archive_verified: true)
        response = get "/jobs/#{job.id}/log.txt", {}, headers
        response.should redirect_to("https://s3.amazonaws.com/archive.travis-ci.org/jobs/#{job.id}/log.txt")
      end
    end

    context 'when log is missing' do
      it 'redirects to archive' do
        job.log.destroy
        response = get "/jobs/#{job.id}/log.txt", {}, headers
        response.should redirect_to("https://s3.amazonaws.com/archive.travis-ci.org/jobs/#{job.id}/log.txt")
      end
    end

    context 'with cors_hax param' do
      it 'renders No Content response with location of the archived log' do
        job.log.destroy
        response = get "/jobs/#{job.id}/log.txt?cors_hax=true", {}, headers
        response.status.should == 204
        response.headers['Location'].should == "https://s3.amazonaws.com/archive.travis-ci.org/jobs/#{job.id}/log.txt"
      end
    end

    context 'with chunked log requested' do
      it 'responds with 406 when log is already aggregated' do
        job.log.update_attributes(aggregated_at: Time.now)
        headers = { 'HTTP_ACCEPT' => 'application/vnd.travis-ci.2+json; chunked=true' }
        response = get "/jobs/#{job.id}/log", {}, headers
        response.status.should == 406
      end

      it 'responds with chunks instead of full log' do
        job.log.parts << Log::Part.new(content: 'foo', number: 1, final: false)
        job.log.parts << Log::Part.new(content: 'bar', number: 2, final: true)

        headers = { 'HTTP_ACCEPT' => 'application/vnd.travis-ci.2+json; chunked=true' }
        response = get "/jobs/#{job.id}/log", {}, headers
        response.should deliver_json_for(job.log, version: 'v2', params: { chunked: true})
      end

      it 'responds with full log if chunks are not available and full log is accepted' do
        job.log.update_attributes(aggregated_at: Time.now)
        headers = { 'HTTP_ACCEPT' => 'application/vnd.travis-ci.2+json; chunked=true, application/vnd.travis-ci.2+json' }
        response = get "/jobs/#{job.id}/log", {}, headers
        response.should deliver_json_for(job.log, version: 'v2')
      end
    end
  end

  it "GET /jobs/:id/annotations" do
    annotation_provider = Factory(:annotation_provider)
    annotation = annotation_provider.annotations.create(job_id: job.id, status: "passed", description: "Foobar")
    response = get "/jobs/#{job.id}/annotations", {}, headers
    response.should deliver_json_for(Annotation.where(id: annotation.id), version: 'v2')
  end

  describe "POST /jobs/:id/annotations" do
    context "with valid credentials" do
      it "responds with a 204" do
        Travis::Services::UpdateAnnotation.any_instance.stubs(:annotations_enabled?).returns(true)

        annotation_provider = Factory(:annotation_provider)
        response = post "/jobs/#{job.id}/annotations", { username: annotation_provider.api_username, key: annotation_provider.api_key, status: "passed", description: "Foobar" }, headers
        response.status.should eq(204)
      end
    end

    context "without a description" do
      it "responds with a 422" do
        annotation_provider = Factory(:annotation_provider)
        response = post "/jobs/#{job.id}/annotations", { username: annotation_provider.api_username, key: annotation_provider.api_key, status: "errored" }, headers
        response.status.should eq(422)
      end
    end

    context "without a status" do
      it "responds with a 422" do
        annotation_provider = Factory(:annotation_provider)
        response = post "/jobs/#{job.id}/annotations", { username: annotation_provider.api_username, key: annotation_provider.api_key, description: "Foobar" }, headers
        response.status.should eq(422)
      end
    end

    context "with invalid credentials" do
      it "responds with a 401" do
        response = post "/jobs/#{job.id}/annotations", { username: "invalid-username", key: "invalid-key", status: "passed", description: "Foobar" }, headers
        response.status.should eq(401)
      end
    end
  end

  describe 'POST /jobs/:id/cancel' do
    let(:user)    { User.where(login: 'svenfuchs').first }
    let(:token)   { Travis::Api::App::AccessToken.create(user: user, app_id: -1) }

    before {
      headers.merge! 'HTTP_AUTHORIZATION' => "token #{token}"
      user.permissions.create!(repository_id: job.repository.id, :push => true, :pull => true)
    }

    context 'when user does not have rights to cancel the job' do
      before { user.permissions.destroy_all }

      it 'responds with 403' do
        response = post "/jobs/#{job.id}/cancel", {}, headers
        response.status.should == 403
      end
    end

    context 'when job is not cancelable' do
      before { job.update_attribute(:state, 'passed') }

      it 'responds with 422' do
        response = post "/jobs/#{job.id}/cancel", {}, headers
        response.status.should == 422
      end
    end

    context 'when job can be canceled' do
      it 'cancels the job and responds with 204' do
        job.update_attribute(:state, 'created')

        response = nil
        expect {
          response = post "/jobs/#{job.id}/cancel", {}, headers
        }.to change { job.reload.state }
        response.status.should == 204

        job.state.should == 'canceled'
      end
    end
  end
end
