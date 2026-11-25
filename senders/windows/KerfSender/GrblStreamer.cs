using System.Collections.Generic;
using System.Text;

namespace KerfSender
{
    /// <summary>
    /// Character-counting streaming: keeps GRBL's receive buffer as full as possible without
    /// overflowing it. Same rules as KerfKutter's GRBLStreamer.
    /// </summary>
    public sealed class GrblStreamer
    {
        public readonly int BufferSize;
        readonly List<string> queue = new List<string>();
        int next;
        readonly Queue<int> inFlight = new Queue<int>();
        int bufferUsed;
        public int Acknowledged { get; private set; }
        public int Errors { get; private set; }

        public GrblStreamer(int bufferSize) { BufferSize = bufferSize > 0 ? bufferSize : 127; }

        public static string Clean(string line)
        {
            string s = line;
            int semi = s.IndexOf(';');
            if (semi >= 0) s = s.Substring(0, semi);
            while (true)
            {
                int open = s.IndexOf('(');
                if (open < 0) break;
                int close = s.IndexOf(')', open);
                if (close < 0) break;
                s = s.Remove(open, close - open + 1);
            }
            s = s.Trim();
            return s.Length == 0 ? null : s;
        }

        public void Enqueue(IEnumerable<string> lines)
        {
            foreach (string l in lines)
            {
                string c = Clean(l);
                if (c != null) queue.Add(c);
            }
        }

        public int Total { get { return queue.Count; } }
        public int Pending { get { return queue.Count - next; } }
        public int InFlightCount { get { return inFlight.Count; } }
        public bool IsIdle { get { return next >= queue.Count && inFlight.Count == 0; } }

        /// <summary>Lines that fit in the controller buffer now; they are counted as in flight.</summary>
        public List<string> TakeSendable()
        {
            var output = new List<string>();
            while (next < queue.Count)
            {
                string line = queue[next];
                int len = Encoding.ASCII.GetByteCount(line) + 1;
                // An over-long line is still sent once the buffer is empty.
                if (bufferUsed + len > BufferSize && !(inFlight.Count == 0 && output.Count == 0)) break;
                output.Add(line);
                inFlight.Enqueue(len);
                bufferUsed += len;
                next++;
            }
            return output;
        }

        public bool Acknowledge(bool isError)
        {
            if (inFlight.Count == 0) return false;
            bufferUsed -= inFlight.Dequeue();
            Acknowledged++;
            if (isError) Errors++;
            return true;
        }

        public void Reset()
        {
            queue.Clear();
            next = 0;
            inFlight.Clear();
            bufferUsed = 0;
            Acknowledged = 0;
            Errors = 0;
        }
    }
}
