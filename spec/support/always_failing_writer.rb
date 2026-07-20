##
# Sink whose every write raises, used to drive a pump into its error path.
class AlwaysFailingWriter
  def write(*) = raise("disk full")
end
