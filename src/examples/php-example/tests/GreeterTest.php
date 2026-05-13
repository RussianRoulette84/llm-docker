<?php

declare(strict_types=1);

namespace PhpExample\Tests;

use PHPUnit\Framework\TestCase;
use PhpExample\Greeter;

final class GreeterTest extends TestCase
{
    public function test_default_stack(): void
    {
        $r = (new Greeter())->hello();
        $this->assertSame('from php-example', $r['hello']);
        $this->assertSame('php-builtin', $r['stack']);
    }

    public function test_custom_stack(): void
    {
        $r = (new Greeter())->hello('laravel');
        $this->assertSame('laravel', $r['stack']);
    }
}
