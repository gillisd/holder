RSpec.describe Holder::Handle do
  describe "the shared escalation clock during a concurrent, shorter-grace teardown" do
    it "never signals the condition variable, so a sleeping waiter is only ever polled" do
      # DESIRED: once a concurrent caller tightens @kill_deadline to a sooner time,
      # the escalation tick should be broadcast so a waiter already sleeping in
      # @escalation_tick.wait(@mutex, POLL) wakes and re-checks at once, rather than
      # lagging up to a full POLL (20ms). await_group_exit's "every caller escalates
      # together" needs that wake-up.
      # CURRENT (asserted here): the condition variable is never sent :signal or
      # :broadcast anywhere, so a tightened deadline is only noticed on the next
      # POLL timeout.
      escalation_tick = instance_spy(ConditionVariable)
      allow(escalation_tick).to receive(:wait) { |mutex, timeout| mutex.sleep(timeout) }
      allow(ConditionVariable).to receive(:new).and_return(escalation_tick)

      handle = spawn_process("sh", "-c", 'trap "" TERM; echo ready; exec sleep 300')
      handle.stdout.gets
      patient = Thread.new { handle.terminate(grace: 2) }
      sleep 0.2
      handle.terminate(grace: 0.2)
      patient.join

      expect(escalation_tick).not_to have_received(:broadcast)
      expect(escalation_tick).not_to have_received(:signal)
    end
  end
end
