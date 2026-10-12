shader_type canvas_item;
render_mode blend_premul_alpha;

// 选中高亮：按贴图自身的 alpha 在轮廓处加一圈颜色。
//
// 原理：中心点加上下左右各采样一次，取这 5 个 alpha 的极差 (maxa - mina)。
//   轮廓处 -> 一侧不透明、一侧透明 -> 极差 > 0 -> 上色
//   内部   -> 5 个采样点全不透明   -> 极差 = 0 -> 不上色
// 所以它画的是"描边"，不是把整张图染色。
//
// aura_width 的单位是【贴图像素】，不是屏幕像素：
//   屏上描边厚度 = aura_width × 节点的 scale。
//   本项目 AnimatedSprite2D 的 scale = 0.3，所以 6.0 大约对应屏上 1.8px。
//   注意贴图换成 AtlasTexture 之后，这里的"贴图像素"是**整张图集**的像素
//   （1152×1536），不是 region 的像素 —— 帧与帧的间隔足够大，采样不会串到邻帧。
// aura_width = 0.0 时 4 个采样点与中心点重合，极差恒为 0 —— 即"关闭高亮"，
// 所以开关高亮就是在这个 0 和一个正值之间切 uniform，不需要换材质。
//
// 注意：本 shader 直接覆写 COLOR，因此 modulate / self_modulate 会被忽略。
// 将来要给棋子染队伍色，**不能**写成 texture(TEXTURE, UV) * COLOR —— Godot 4 片元入口的
// COLOR 已经包含贴图颜色了（COLOR == modulate × texture），再乘一次会把贴图平方、整体变暗。
// 正确做法是在 vertex() 里把 COLOR 存进 varying，片元最后再乘回去。
//
// 描边**只画在轮廓外侧**（见 fragment 末尾的遮罩），不会盖住原画。
// 代价是视觉厚度约为 aura_width 的一半多一点 —— 觉得细就把 aura_width 调大。
//
// 另有一个踩了就很难查的坑：贴图的导入选项 "Premultiply Alpha" 必须保持关闭，
// 否则 RGB 在贴图里已经预乘过一次，这里再 col.rgb *= col.a 会乘第二次，棋子整体发暗。

uniform float aura_width = 2.0;
uniform vec4 aura_color : source_color;

void fragment() {
	vec4 col = texture(TEXTURE, UV);
	vec2 ps = TEXTURE_PIXEL_SIZE;
	float a;
	float maxa = col.a;
	float mina = col.a;

	a = texture(TEXTURE, UV + vec2(0.0, -aura_width) * ps).a;
	maxa = max(a, maxa);
	mina = min(a, mina);

	a = texture(TEXTURE, UV + vec2(0.0, aura_width) * ps).a;
	maxa = max(a, maxa);
	mina = min(a, mina);

	a = texture(TEXTURE, UV + vec2(-aura_width, 0.0) * ps).a;
	maxa = max(a, maxa);
	mina = min(a, mina);

	a = texture(TEXTURE, UV + vec2(aura_width, 0.0) * ps).a;
	maxa = max(a, maxa);
	mina = min(a, mina);

	col.rgb *= col.a; // 预乘 alpha，配合 blend_premul_alpha

	COLOR = col;
	// 描边像素自身的 alpha 是 0，而 blend_premul_alpha 下 alpha = 0 退化成加法混合，
	// 所以轮廓外侧也能把颜色加上去。
	//
	// **乘上 (1 - step(0.5, col.a)) 是关键**：`maxa - mina` 在轮廓**内侧**同样非零
	//（离边缘 q 个 texel 的像素，只要 q < aura_width 就算"边缘"），不加这个遮罩的话
	// 一半的描边会盖在画面上洗一层颜色 —— 老的低细节贴图看不出来，换成细节丰富的
	// 角色贴图就会明显遮挡原画。
	// 现在只在**中心像素本身接近透明**的地方上色，也就是只画轮廓外侧。
	COLOR.rgb += aura_color.rgb * (maxa - mina) * (1.0 - step(0.5, col.a));
}
