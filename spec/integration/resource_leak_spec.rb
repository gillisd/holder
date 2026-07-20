# These sample process-global counts, so they must never run concurrently with
# another process-spawning example: its transient pipes and pump threads would
# read as this example's leak. RSpec runs examples serially, which is what
# holds that today.
#
# 90 spawn/teardown cycles apiece is legitimate work that outgrows the tier's
# 3s budget on a loaded runner -- macOS has tipped past it on scheduling
# variance alone -- so each states a budget sized to the churn while still
# catching a genuine wedge.
RSpec.describe "a full spawn/teardown cycle, repeated" do
  let(:leak_cycles) { 30 }

  def growth_across_churn
    GC.start
    before = yield
    churn_processes(leak_cycles)
    GC.start
    sleep 0.2
    yield - before
  end

  it "hands every file descriptor it opened back to the process", timeout: 10 do
    expect(growth_across_churn { fd_count }).to be <= 2
  end

  it "hands every thread it started back to the process", timeout: 10 do
    expect(growth_across_churn { Thread.list.size }).to be <= 2
  end
end
