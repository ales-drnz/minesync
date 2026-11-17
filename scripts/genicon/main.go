// genicon: genera l'icona MineSync identica al logo della navbar web — cubo in
// TRATTO BIANCO su quadrato verde #3C8527 arrotondato — come PNG 256x256 e .ico
// (PNG-in-ICO). Il cubo è in proiezione isometrica esatta: vedi isoCube.
// Il logo della navbar (icons.box in web/static/app.js) e la favicon SVG
// (web/static/favicon.svg) usano lo stesso disegno, tenuto a mano in SVG: se
// cambi la geometria qui, cambiala anche là.
//
// Con -web <dir> scrive anche le favicon della web UI, disegnate alla misura
// finale (non ridimensionate): favicon.ico (16/32/48), favicon-32.png e
// apple-touch-icon.png (180, a tutto campo: iOS arrotonda da sé gli angoli).
package main

import (
	"bytes"
	"encoding/binary"
	"flag"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"log"
	"math"
	"os"
	"path/filepath"

	"golang.org/x/image/vector"
)

type pt struct{ x, y float32 }

func fillPath(dst *image.RGBA, c color.RGBA, build func(r *vector.Rasterizer)) {
	b := dst.Bounds()
	r := vector.NewRasterizer(b.Dx(), b.Dy())
	build(r)
	r.ClosePath()
	r.Draw(dst, dst.Bounds(), image.NewUniform(c), image.Point{})
}

func roundedRect(r *vector.Rasterizer, x0, y0, x1, y1, rad float32) {
	r.MoveTo(x0+rad, y0)
	r.LineTo(x1-rad, y0)
	r.QuadTo(x1, y0, x1, y0+rad)
	r.LineTo(x1, y1-rad)
	r.QuadTo(x1, y1, x1-rad, y1)
	r.LineTo(x0+rad, y1)
	r.QuadTo(x0, y1, x0, y1-rad)
	r.LineTo(x0, y0+rad)
	r.QuadTo(x0, y0, x0+rad, y0)
}

// seg disegna il corpo di un tratto spesso (le estremità tonde sono
// dischi disegnati in passate separate).
func seg(r *vector.Rasterizer, a, b pt, w float32) {
	dx, dy := b.x-a.x, b.y-a.y
	l := float32(math.Hypot(float64(dx), float64(dy)))
	if l == 0 {
		return
	}
	nx, ny := -dy/l*w/2, dx/l*w/2
	r.MoveTo(a.x+nx, a.y+ny)
	r.LineTo(b.x+nx, b.y+ny)
	r.LineTo(b.x-nx, b.y-ny)
	r.LineTo(a.x-nx, a.y-ny)
	r.ClosePath()
}

func disc(r *vector.Rasterizer, c pt, rad float32) {
	const n = 24
	for i := 0; i <= n; i++ {
		ang := 2 * math.Pi * float64(i) / n
		x := c.x + rad*float32(math.Cos(ang))
		y := c.y + rad*float32(math.Sin(ang))
		if i == 0 {
			r.MoveTo(x, y)
		} else {
			r.LineTo(x, y)
		}
	}
	r.ClosePath()
}

// isoCube restituisce i 9 spigoli visibili di un cubo isometrico di centro c e
// circumraggio R. Un cubo in proiezione isometrica si proietta in un esagono
// REGOLARE con i tre spigoli frontali che convergono nel centro: tutti e nove i
// segmenti misurano R, i lati obliqui stanno a 30° dall'orizzontale e i tre assi
// a 120° l'uno dall'altro. Ingombro: √3R di larghezza per 2R di altezza.
//
// (Il cubo "box" di lucide, usato fino alla 1.5.1, NON rispetta niente di tutto
// questo — lati 8 contro 10.67, obliqui a 32.5° — e si legge come una scatola
// schiacciata invece che come un cubo.)
func isoCube(c pt, R float32) [][2]pt {
	const cos30 = 0.8660254 // √3/2
	v := func(dx, dy float32) pt { return pt{c.x + dx, c.y + dy} }
	top, bot := v(0, -R), v(0, R)
	ur, lr := v(cos30*R, -R/2), v(cos30*R, R/2)
	ul, ll := v(-cos30*R, -R/2), v(-cos30*R, R/2)
	return [][2]pt{
		{top, ur}, {ur, lr}, {lr, bot}, {bot, ll}, {ll, ul}, {ul, top}, // esagono
		{c, ul}, {c, ur}, {c, bot}, // spigoli frontali
	}
}

// render disegna l'icona su una tela quadrata di lato size. Le misure sono
// quelle della versione 256 (margine 6, raggio 52, cubo a sc 8.2) scalate in
// proporzione; full = sfondo a tutto campo senza margine né angoli tondi.
func render(size int, full bool) *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, size, size))
	draw.Draw(img, img.Bounds(), image.Transparent, image.Point{}, draw.Src)
	k := float32(size) / 256
	S := float32(size)

	// sfondo: quadrato arrotondato nel verde della navbar (--green #3c8527)
	fillPath(img, color.RGBA{0x3c, 0x85, 0x27, 255}, func(r *vector.Rasterizer) {
		if full {
			r.MoveTo(0, 0)
			r.LineTo(S, 0)
			r.LineTo(S, S)
			r.LineTo(0, S)
			return
		}
		roundedRect(r, 6*k, 6*k, S-6*k, S-6*k, 52*k)
	})

	// cubo bianco centrato, con le proporzioni dell'SVG della navbar (viewBox
	// 24, circumraggio 10, stroke-width 2). sc < 256/24 perché il cubo dentro
	// l'icona sta a scale(0.77) come nella favicon: lascia aria sui bordi.
	sc := 8.2 * k
	if full {
		sc = 7.2 * k // a tutto campo il cubo resta dentro la maschera arrotondata di iOS
	}
	segs := isoCube(pt{S / 2, S / 2}, 10*sc)
	w := 2 * sc
	// una passata per forma: sovrapposizioni con winding opposto si
	// annullerebbero dentro lo stesso rasterizer
	white := color.RGBA{255, 255, 255, 255}
	for _, sgm := range segs {
		a, b := sgm[0], sgm[1]
		fillPath(img, white, func(r *vector.Rasterizer) { seg(r, a, b, w) })
		fillPath(img, white, func(r *vector.Rasterizer) { disc(r, a, w/2) })
		fillPath(img, white, func(r *vector.Rasterizer) { disc(r, b, w/2) })
	}
	return img
}

func encodePNG(img image.Image) []byte {
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		log.Fatal(err)
	}
	return buf.Bytes()
}

// encodeICO impacchetta delle PNG quadrate in un .ico (PNG-in-ICO); 256 si
// scrive 0 nell'intestazione.
func encodeICO(sizes []int, pngs [][]byte) []byte {
	var ico bytes.Buffer
	binary.Write(&ico, binary.LittleEndian, uint16(0))
	binary.Write(&ico, binary.LittleEndian, uint16(1))
	binary.Write(&ico, binary.LittleEndian, uint16(len(pngs)))
	off := 6 + 16*len(pngs)
	for i, p := range pngs {
		d := byte(sizes[i] % 256)
		ico.WriteByte(d)
		ico.WriteByte(d)
		ico.WriteByte(0)
		ico.WriteByte(0)
		binary.Write(&ico, binary.LittleEndian, uint16(1))
		binary.Write(&ico, binary.LittleEndian, uint16(32))
		binary.Write(&ico, binary.LittleEndian, uint32(len(p)))
		binary.Write(&ico, binary.LittleEndian, uint32(off))
		off += len(p)
	}
	for _, p := range pngs {
		ico.Write(p)
	}
	return ico.Bytes()
}

func write(path string, b []byte) {
	if err := os.WriteFile(path, b, 0o644); err != nil {
		log.Fatal(err)
	}
}

func main() {
	web := flag.String("web", "", "cartella in cui scrivere anche le favicon della web UI")
	flag.Parse()

	big := encodePNG(render(256, false))
	write("icon.png", big)
	write("icon.ico", encodeICO([]int{256}, [][]byte{big}))
	log.Println("icon.png + icon.ico generati (stile navbar)")

	if *web == "" {
		return
	}
	sizes := []int{16, 32, 48}
	var pngs [][]byte
	for _, n := range sizes {
		pngs = append(pngs, encodePNG(render(n, false)))
	}
	write(filepath.Join(*web, "favicon.ico"), encodeICO(sizes, pngs))
	write(filepath.Join(*web, "favicon-32.png"), pngs[1])
	write(filepath.Join(*web, "apple-touch-icon.png"), encodePNG(render(180, true)))
	log.Println("favicon.ico, favicon-32.png, apple-touch-icon.png in", *web)
}
