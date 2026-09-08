#!/usr/bin/env python3
"""Make samsung_pinctrl_probe() say what it is doing.

Two pin controllers were added for this SoC and neither produced a single
line of kernel output -- no probe, no error, not even the "Missing node for
bank" warning -- while the touch SPI sat forever waiting for a supplier
called gpn0-gpio-bank. Everything checkable from the host checks out: the
compatible is in the built Image, the alias resolves in the built DTB, the
bank table names gpn0..gpn9, and the driver is built in and registered at
postcore_initcall.

That leaves the paths in samsung_pinctrl_probe() that fail with a bare
"goto err_put_banks" and print nothing at all. This makes each of them
speak, and adds an entry and an exit line so a boot log can distinguish
"probe never ran" from "probe ran and failed at step N".

Diagnostic only. Delete once the answer is known.
"""
import sys

p = "drivers/pinctrl/samsung/pinctrl-samsung.c"
s = open(p).read()

if "pinctrl-loud" in s:
    sys.exit("pinctrl-loud: already applied")

subs = [
    # entry
    ("""	drvdata = devm_kzalloc(dev, sizeof(*drvdata), GFP_KERNEL);
	if (!drvdata)
		return -ENOMEM;
""",
     """	drvdata = devm_kzalloc(dev, sizeof(*drvdata), GFP_KERNEL);
	if (!drvdata)
		return -ENOMEM;

	dev_info(dev, "pinctrl-loud: probe entered\\n");
"""),
    # after soc data
    ("""	drvdata->dev = dev;

	ret = platform_get_irq_optional(pdev, 0);
	if (ret < 0 && ret != -ENXIO)
		goto err_put_banks;
""",
     """	drvdata->dev = dev;
	dev_info(dev, "pinctrl-loud: soc data ok, %u banks\\n", drvdata->nr_banks);

	ret = platform_get_irq_optional(pdev, 0);
	if (ret < 0 && ret != -ENXIO) {
		dev_err(dev, "pinctrl-loud: irq_optional %d\\n", ret);
		goto err_put_banks;
	}
"""),
    # retention
    ("""		if (IS_ERR(drvdata->retention_ctrl)) {
			ret = PTR_ERR(drvdata->retention_ctrl);
			goto err_put_banks;
		}
""",
     """		if (IS_ERR(drvdata->retention_ctrl)) {
			ret = PTR_ERR(drvdata->retention_ctrl);
			dev_err(dev, "pinctrl-loud: retention %d\\n", ret);
			goto err_put_banks;
		}
"""),
    # pclk
    ("""	drvdata->pclk = devm_clk_get_optional_prepared(dev, "pclk");
	if (IS_ERR(drvdata->pclk)) {
		ret = PTR_ERR(drvdata->pclk);
		goto err_put_banks;
	}

	ret = samsung_pinctrl_register(pdev, drvdata);
	if (ret)
		goto err_put_banks;
""",
     """	drvdata->pclk = devm_clk_get_optional_prepared(dev, "pclk");
	if (IS_ERR(drvdata->pclk)) {
		ret = PTR_ERR(drvdata->pclk);
		dev_err(dev, "pinctrl-loud: pclk %d\\n", ret);
		goto err_put_banks;
	}

	ret = samsung_pinctrl_register(pdev, drvdata);
	if (ret) {
		dev_err(dev, "pinctrl-loud: pinctrl_register %d\\n", ret);
		goto err_put_banks;
	}
	dev_info(dev, "pinctrl-loud: pinctrl registered\\n");
"""),
    # gpiolib + enable
    ("""	ret = samsung_gpiolib_register(pdev, drvdata);
	if (ret)
		goto err_unregister;

	ret = pinctrl_enable(drvdata->pctl_dev);
	if (ret)
		goto err_unregister;

	platform_set_drvdata(pdev, drvdata);

	return 0;
""",
     """	ret = samsung_gpiolib_register(pdev, drvdata);
	if (ret) {
		dev_err(dev, "pinctrl-loud: gpiolib_register %d\\n", ret);
		goto err_unregister;
	}

	ret = pinctrl_enable(drvdata->pctl_dev);
	if (ret) {
		dev_err(dev, "pinctrl-loud: pinctrl_enable %d\\n", ret);
		goto err_unregister;
	}

	platform_set_drvdata(pdev, drvdata);
	dev_info(dev, "pinctrl-loud: probe OK\\n");

	return 0;
"""),
]

for old, new in subs:
    if old not in s:
        sys.exit("pinctrl-loud: anchor moved:\n%s" % old)
    if s.count(old) != 1:
        sys.exit("pinctrl-loud: anchor not unique:\n%s" % old)
    s = s.replace(old, new)

open(p, "w").write(s)
print("pinctrl-loud: ok")
