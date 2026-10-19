// Test MIDlet for tests/smoke-core.sh, never shipped. It paints the whole
// canvas #336699 and, from a second thread, keeps printing the kind of line
// Diamond Rush prints on every key event. In libretro mode FreeJ2ME's stdout
// is the frame pipe, so unless the jar keeps the two apart those lines land
// inside frames and shift their bytes.

import javax.microedition.lcdui.Canvas;
import javax.microedition.lcdui.Display;
import javax.microedition.lcdui.Graphics;
import javax.microedition.midlet.MIDlet;

public class NoisyProbe extends MIDlet implements Runnable
{
	Canvas canvas;
	volatile boolean running;

	public void startApp()
	{
		if (canvas == null)
		{
			canvas = new Canvas()
			{
				protected void paint(Graphics g)
				{
					g.setColor(0x336699);
					g.fillRect(0, 0, getWidth(), getHeight());
				}
			};
			Display.getDisplay(this).setCurrent(canvas);
			running = true;
			new Thread(this).start();
		}
	}

	public void run()
	{
		int i = 0;
		while (running)
		{
			System.out.println("keyPressed:-5");
			if (++i % 100 == 0) { canvas.repaint(); }
			try { Thread.sleep(1); } catch (InterruptedException e) { }
		}
	}

	public void pauseApp() { }

	public void destroyApp(boolean unconditional) { running = false; }
}
