using System;
using System.Windows.Forms;

namespace KerfSender
{
    static class Program
    {
        [STAThread]
        static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.ThreadException += (s, e) =>
                MessageBox.Show("Something went wrong: " + e.Exception.Message, "KerfSender",
                                MessageBoxButtons.OK, MessageBoxIcon.Error);
            Application.Run(new MainForm(args.Length > 0 ? args[0] : null));
        }
    }
}
