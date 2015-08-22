require_relative 'concern/dereferenceable_shared'
require_relative 'concern/observable_shared'

module Concurrent

  describe Agent do

    it 'posts a job' do
      subject = Agent.new(0)
      subject.send_via(Concurrent::ImmediateExecutor.new) {|value| 10 }
      expect(subject.value).to eq 10
    end
  end
end
